# Architecture (Jailbreak iOS Proxy)

## Components

- `Minecraft process` (target app)
- `Injected tweak` (Theos/Logos) for traffic redirection and optional overlay
- `proxyd` or `proxyd-c` (launchd daemon) for relay logic + control API
- `Web backend/dashboard` for remote start/stop commands

## Recommended Flow

1. Web dashboard sends command to backend (`start`, `stop`, `toggle`)
2. `proxyd` polls backend (or receives push via future websocket)
3. `proxyd` updates local proxy runtime state
4. Tweak redirects Minecraft traffic to `127.0.0.1:<localProxyPort>`
5. `proxyd` forwards packets to configured remote Bedrock server

For no-Mac workflows, replace `proxyd` with `proxyd-c` (C/BSD sockets implementation).

## Local Control API (current scaffold)

- `GET /healthz`
- `GET /status`
- `POST /proxy/start`
- `POST /proxy/stop`
- `POST /proxy/toggle`

Auth:

- `Authorization: Bearer <controlAuthToken>`

Start body (optional JSON):

```json
{
  "serverHost": "play.example.net",
  "serverPort": 19132
}
```

## Security Notes

- Do not expose the local control API publicly without authentication
- Add signed command verification before trusting web/backend commands
- Add replay protection (`nonce`, `timestamp`, short expiration)
