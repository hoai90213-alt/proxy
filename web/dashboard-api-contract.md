# Web Dashboard API Contract (Suggested)

This is a suggested backend contract if you want a website button to control the iOS daemon.

## Model

- User logs in to website
- Website targets a specific `deviceId`
- Backend stores or emits one command
- `proxyd` polls backend and applies latest command

## Endpoint Example (backend -> daemon poll)

`GET /api/devices/{deviceId}/commands/next`

Headers:

- `Authorization: Bearer <device-service-token>`
- `X-Device-Id: <deviceId>`

Response: either empty body (no command) or one command object:

```json
{
  "command": "toggle",
  "commandId": "cmd_abc123",
  "deviceId": "e3f6b490-a5f0-4fbe-9b8f-8d965db17b61",
  "serverHost": "play.example.net",
  "serverPort": 19132,
  "nonce": "8f2a2f2c8b1f4ee2",
  "timestamp": "2026-02-26T12:34:56Z",
  "signature": "BASE64_SIGNATURE"
}
```

## Security Requirements (Recommended)

- Command signed server-side (Ed25519 recommended)
- Device validates signature
- Command includes `nonce` + `timestamp`
- Backend marks command consumed after device ack
- Device sends ack endpoint after apply:
  - `POST /api/devices/{deviceId}/commands/{commandId}/ack`

## Why Polling First

Polling is easier to stabilize on jailbreak setups than websocket background reliability.
You can add websocket later after proxy runtime is stable.

