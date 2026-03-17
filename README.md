# Aether

Minimal Flutter app named Aether with a Discord-inspired dark theme.

Run:

```bash
flutter pub get
flutter run
```

## Backend URL (important for APKs)

The app talks to the Node backend in [backend/](backend/) via HTTP + WebSocket.

- Android emulator: `http://10.0.2.2:8080`
- Physical phone: use your PC LAN IP (example: `http://192.168.1.50:8080`)
- Cloud: use your deployed HTTPS URL (example: `https://your-service.onrender.com`)

You can bake the backend URL into the build with `--dart-define`:

```bash
flutter build apk --debug --dart-define=AETHER_BASE_URL=https://YOUR_BACKEND_HOST
```

The WebSocket URL is derived from the same base URL (`ws://` or `wss://`).
