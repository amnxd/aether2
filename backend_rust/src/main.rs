use actix_web::{web, App, HttpResponse, HttpServer, Responder};
use actix_web::{HttpRequest, HttpResponse as ActixHttpResponse};
use actix_web_actors::ws;
use actix::prelude::*;
use bcrypt::{hash, verify};
use jsonwebtoken::{encode, decode, EncodingKey, DecodingKey, Header, Validation};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::env;
use std::sync::{Mutex, Arc};
use std::sync::atomic::{AtomicUsize, Ordering};

static EMAIL_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[^@\s]+@[^@\s]+\.[^@\s]+$").unwrap());

#[derive(Clone, Serialize, Deserialize)]
struct UserSafe {
    id: usize,
    email: String,
}

#[derive(Clone)]
struct User {
    id: usize,
    email: String,
    password_hash: String,
}

#[derive(Deserialize)]
struct AuthRequest {
    email: String,
    password: String,
}

#[derive(Serialize, Deserialize)]
struct Claims {
    sub: String,
    exp: usize,
}

struct AppState {
    users: Mutex<HashMap<usize, User>>,
    next_id: AtomicUsize,
    jwt_secret: String,
}

// Simple global session list for broadcasting messages
type BroadcastRecipient = actix::prelude::Recipient<BroadcastMessage>;
static mut SESSIONS: Option<Mutex<Vec<BroadcastRecipient>>> = None;

#[derive(Message)]
#[rtype(result = "()")] 
struct BroadcastMessage(String);

struct WsSession {
    user_email: String,
}

impl Actor for WsSession {
    type Context = ws::WebsocketContext<Self>;

    fn started(&mut self, ctx: &mut Self::Context) {
        let rec = ctx.address().recipient::<BroadcastMessage>();
        unsafe {
            if let Some(m) = &SESSIONS {
                m.lock().unwrap().push(rec);
            }
        }
    }

    fn stopped(&mut self, _ctx: &mut Self::Context) {
        // For simplicity we don't remove recipients here; a production server should clean up.
    }
}

impl StreamHandler<Result<ws::Message, ws::ProtocolError>> for WsSession {
    fn handle(&mut self, item: Result<ws::Message, ws::ProtocolError>, ctx: &mut Self::Context) {
        match item {
            Ok(ws::Message::Text(text)) => {
                // Broadcast to all recipients as JSON with sender = this session's user_email
                let payload = serde_json::json!({"sender": self.user_email, "text": text, "time": chrono::Utc::now().to_rfc3339()});
                let msg = BroadcastMessage(payload.to_string());
                unsafe {
                    if let Some(m) = &SESSIONS {
                        for rec in m.lock().unwrap().iter() {
                            let _ = rec.do_send(msg.clone());
                        }
                    }
                }
            }
            Ok(ws::Message::Ping(p)) => ctx.pong(&p),
            Ok(ws::Message::Close(_)) => ctx.stop(),
            _ => {}
        }
    }
}

impl Handler<BroadcastMessage> for WsSession {
    type Result = ();

    fn handle(&mut self, msg: BroadcastMessage, ctx: &mut Self::Context) -> Self::Result {
        ctx.text(msg.0);
    }
}

async fn ws_index(req: HttpRequest, stream: web::Payload) -> Result<ActixHttpResponse, actix_web::Error> {
    // initialize sessions container once
    unsafe {
        if SESSIONS.is_none() {
            SESSIONS = Some(Mutex::new(Vec::new()));
        }
    }

    // Extract token from query param: /ws?token=...
    let qs = req.query_string();
    let token_opt = qs.split('&').find_map(|kv| {
        let mut parts = kv.splitn(2, '=');
        match (parts.next(), parts.next()) {
            (Some(k), Some(v)) if k == "token" => Some(v.to_string()),
            _ => None,
        }
    });

    let token = match token_opt {
        Some(t) => t,
        None => return Ok(ActixHttpResponse::Unauthorized().finish()),
    };

    if verify_jwt(&req.app_data::<web::Data<Arc<AppState>>>().unwrap().jwt_secret, &token).is_err() {
        return Ok(ActixHttpResponse::Unauthorized().finish());
    }

    // decode to get sub/email if needed
    let claims = decode::<Claims>(&token, &DecodingKey::from_secret(req.app_data::<web::Data<Arc<AppState>>>().unwrap().jwt_secret.as_ref()), &Validation::default());
    let user_email = match claims {
        Ok(data) => data.claims.sub, // we stored sub as id string; in this scaffold email isn't in claims, so keep sub
        Err(_) => "unknown".to_string(),
    };

    ws::start(WsSession { user_email }, &req, stream)
}

async fn signup(state: web::Data<Arc<AppState>>, req: web::Json<AuthRequest>) -> impl Responder {
    let email = req.email.trim().to_lowercase();
    let password = req.password.clone();
    if !EMAIL_RE.is_match(&email) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error":"Invalid email"}));
    }
    if password.len() < 6 {
        return HttpResponse::BadRequest().json(serde_json::json!({"error":"Password must be at least 6 characters"}));
    }

    let mut users = state.users.lock().unwrap();
    if users.values().any(|u| u.email == email) {
        return HttpResponse::Conflict().json(serde_json::json!({"error":"User already exists"}));
    }

    let id = state.next_id.fetch_add(1, Ordering::SeqCst);
    let password_hash = match hash(&password, 12) {
        Ok(h) => h,
        Err(_) => return HttpResponse::InternalServerError().finish(),
    };

    let user = User { id, email: email.clone(), password_hash };
    users.insert(id, user);

    let token = create_jwt(&state.jwt_secret, id, &email);

    HttpResponse::Created().json(serde_json::json!({"id": id, "email": email, "token": token}))
}

async fn login(state: web::Data<Arc<AppState>>, req: web::Json<AuthRequest>) -> impl Responder {
    let email = req.email.trim().to_lowercase();
    let password = req.password.clone();
    if !EMAIL_RE.is_match(&email) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error":"Invalid email"}));
    }
    if password.len() < 6 {
        return HttpResponse::BadRequest().json(serde_json::json!({"error":"Invalid password"}));
    }

    let users = state.users.lock().unwrap();
    let user = match users.values().find(|u| u.email == email) {
        Some(u) => u.clone(),
        None => return HttpResponse::Unauthorized().json(serde_json::json!({"error":"Invalid credentials"})),
    };

    if let Ok(ok) = verify(&password, &user.password_hash) {
        if !ok {
            return HttpResponse::Unauthorized().json(serde_json::json!({"error":"Invalid credentials"}));
        }
    } else {
        return HttpResponse::InternalServerError().finish();
    }

    let token = create_jwt(&state.jwt_secret, user.id, &user.email);
    HttpResponse::Ok().json(serde_json::json!({"message":"Login successful","user":{"id": user.id, "email": user.email}, "token": token}))
}

fn create_jwt(secret: &str, user_id: usize, email: &str) -> String {
    let exp = (chrono::Utc::now() + chrono::Duration::hours(1)).timestamp() as usize;
    let claims = Claims { sub: user_id.to_string(), exp };
    encode(&Header::default(), &claims, &EncodingKey::from_secret(secret.as_ref())).unwrap_or_default()
}

fn verify_jwt(secret: &str, token: &str) -> Result<Claims, ()> {
    match decode::<Claims>(token, &DecodingKey::from_secret(secret.as_ref()), &Validation::default()) {
        Ok(data) => Ok(data.claims),
        Err(_) => Err(()),
    }
}

async fn users_handler(state: web::Data<Arc<AppState>>, req: actix_web::HttpRequest) -> impl Responder {
    let auth = req.headers().get("authorization");
    if auth.is_none() {
        return HttpResponse::Unauthorized().json(serde_json::json!({"error":"Missing token"}));
    }
    let auth = auth.unwrap().to_str().unwrap_or("");
    if !auth.starts_with("Bearer ") {
        return HttpResponse::Unauthorized().json(serde_json::json!({"error":"Missing token"}));
    }
    let token = &auth[7..];
    if verify_jwt(&state.jwt_secret, token).is_err() {
        return HttpResponse::Unauthorized().json(serde_json::json!({"error":"Invalid token"}));
    }

    let users = state.users.lock().unwrap();
    let safe: Vec<UserSafe> = users.values().map(|u| UserSafe { id: u.id, email: u.email.clone() }).collect();
    HttpResponse::Ok().json(safe)
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let jwt_secret = env::var("JWT_SECRET").unwrap_or_else(|_| "dev-secret".to_string());
    let state = Arc::new(AppState { users: Mutex::new(HashMap::new()), next_id: AtomicUsize::new(1), jwt_secret });

    println!("Aether Rust backend listening on 0.0.0.0:8080");
    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(state.clone()))
            .route("/signup", web::post().to(signup))
            .route("/login", web::post().to(login))
            .route("/users", web::get().to(users_handler))
            .route("/ws", web::get().to(ws_index))
    })
    .bind(("0.0.0.0", 8080))?
    .run()
    .await
}
