# Aether Backend (Rust / Actix-web)

Scaffolded Actix-web REST API. This is optional — Rust may not be installed locally.

Build & run (requires Rust toolchain):

```bash
cd backend_rust
cargo run
```

Server listens on port `8080` by default.

Endpoints:

- `POST /signup` { "email": "...", "password": "..." } -> 201 { id, email, token }
- `POST /login` { "email": "...", "password": "..." } -> 200 { message, user, token }
- `GET /users` -> 200 [ { id, email } ] (requires Bearer token)

Notes:

- Uses in-memory store; not suitable for production.
- JWT secret comes from `JWT_SECRET` env var; default is `dev-secret`.
- Passwords hashed with `bcrypt`.
