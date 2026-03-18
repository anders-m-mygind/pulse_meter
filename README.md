# pulse_meter

Flutter app for capturing meeting notes and sending transcript data to a backend.

## Local Backend

Start the backend server from the repo root:

```bash
dart run backend/server.dart
```

By default it listens on `http://0.0.0.0:8080`.

Endpoints:
- `GET /health`
- `POST /v1/meeting-notes/process`

## Point The App To Backend

The app reads the backend endpoint from:
- `MEETING_PROCESS_ENDPOINT` (`--dart-define`)

If not provided, it defaults to:
- `http://127.0.0.1:8080/v1/meeting-notes/process`

### Simulator

```bash
flutter run --dart-define=MEETING_PROCESS_ENDPOINT=http://127.0.0.1:8080/v1/meeting-notes/process
```

### Physical iPhone

1. Find your Mac LAN IP (example):
```bash
ipconfig getifaddr en0
```
2. Run Flutter with that IP:
```bash
flutter run --dart-define=MEETING_PROCESS_ENDPOINT=http://<YOUR_MAC_LAN_IP>:8080/v1/meeting-notes/process
```
