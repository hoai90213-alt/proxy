# Control Protocol (Daemon API)

This document describes the local daemon control API and a suggested remote command payload for web dashboards.

## Local Daemon API

Base URL (default):

- `http://127.0.0.1:8787`

Header:

- `Authorization: Bearer <controlAuthToken>`

Endpoints:

- `GET /healthz`
- `GET /status`
- `POST /proxy/start`
- `POST /proxy/stop`
- `POST /proxy/toggle`

Optional body for `start` / `toggle`:

```json
{
  "serverHost": "play.example.net",
  "serverPort": 19132
}
```

Status response example:

```json
{
  "state": "running",
  "localProxyPort": 19132,
  "target": {
    "serverHost": "play.example.net",
    "serverPort": 19132
  },
  "updatedAt": "2026-02-26T12:00:00Z",
  "message": "Proxy running (stub)"
}
```

## Remote Web Command Payload (Suggested)

The scaffold poller expects one JSON command object from a backend:

```json
{
  "command": "start",
  "commandId": "cmd_123",
  "deviceId": "ios-device-001",
  "serverHost": "play.example.net",
  "serverPort": 19132,
  "nonce": "random-string",
  "timestamp": "2026-02-26T12:00:00Z",
  "signature": "base64-signature"
}
```

The current scaffold only validates timestamp skew (if provided). Signature verification is still TODO.

