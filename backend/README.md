# Aether Backend (Node/Express)

REST + WebSocket backend for the Aether Flutter app.

## Run locally (Node)

```bash
cd backend
npm install
DATABASE_URL="postgres://user:pass@localhost:5432/aether" npm start
```

Server listens on port `8080` by default.

This backend uses PostgreSQL for users + message persistence.

### Required environment variables

- `DATABASE_URL` (required): PostgreSQL connection string
- `DATABASE_SSL` (optional): set to `true` to force SSL (common on Render-managed Postgres)
- `PGSSLMODE` (optional): if set to `require`/`verify-*`, SSL is enabled
- `JWT_SECRET` (recommended): set to a long random string in production
- `PORT` (optional): default `8080`

Endpoints:

- `POST /signup` { email, password } -> 201 { id, email, token }
- `POST /login` { email, password } -> 200 { message, user, token }
- `GET /users` -> 200 [ { id, email } ] (requires Bearer token)
- `GET /chats/:id/messages` -> 200 [ ... ] (requires Bearer token)

Passwords are hashed with `bcryptjs` and stored in Postgres.

JWT / CORS

- The server issues a JWT on successful signup/login. Set `JWT_SECRET` environment variable to a secure value in production. Default is `dev-secret`.
- `/users` requires a bearer token in the `Authorization: Bearer <token>` header.
- CORS is enabled by default for development.

WebSocket

- A WebSocket server is available at `/ws`. Connect with a WebSocket client and any message sent by one client will be broadcast to all connected clients.
- The Flutter client connects using `ws(s)://<host>/ws?token=<jwt>`.

## Container / Cloud

This repo includes a production Dockerfile: [backend/Dockerfile](backend/Dockerfile)

### Option A: Render.com (easy)

1. Create a managed Postgres on Render.
2. Create a new Web Service from your GitHub repo.
3. Set:
   - Root directory: `backend`
   - Build command: `npm ci --omit=dev`
   - Start command: `node index.js`
  - Env vars: `DATABASE_URL`, `JWT_SECRET` (and typically `DATABASE_SSL=true`)
4. Deploy. You’ll get a URL like `https://your-service.onrender.com`.

### Option B: Docker (any VPS / Fly.io / Azure Container Apps)

Build and run:

```bash
docker build -t aether-backend ./backend
docker run -p 8080:8080 \
  -e PORT=8080 \
  -e JWT_SECRET="change-me" \
  -e DATABASE_URL="postgres://..." \
  aether-backend
```

Example login response:

```json
{
  "message": "Login successful",
  "user": { "id": 1, "email": "you@example.com" },
  "token": "<jwt>"
}
```
