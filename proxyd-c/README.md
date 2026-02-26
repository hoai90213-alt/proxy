# proxyd-c (No-Mac Path)

`proxyd-c` is a C/BSD-sockets daemon variant intended for Windows + WSL + Theos workflows (no macOS required).

What it supports now:

- Local HTTP control API:
  - `GET /healthz`
  - `GET /status`
  - `POST /proxy/start`
  - `POST /proxy/stop`
  - `POST /proxy/toggle`
- UDP pass-through relay (single active client, IPv4 loopback local bind)
- Bearer token auth for control API

What it does not support yet:

- Web command polling (from dashboard backend)
- Packet parsing / protocol-aware hooks
- IPv6 local relay socket (current local bind is `127.0.0.1`)

## Build (WSL/Linux)

```bash
cd proxyd-c
make
./luminaproxyd ./example-config.json
```

Or from repo root using helper script:

```bash
./scripts/build-all.sh
```

## Build (Theos / iPhone)

```bash
cd proxyd-c
make package
```

If using rootless packaging, export `THEOS_PACKAGE_SCHEME=rootless` before building.

Or use helper script from repo root:

```bash
./scripts/build-all.sh --theos --scheme rootless
```

## Deploy / Logs (WSL -> iPhone)

Use helper scripts from repo root:

```bash
./scripts/deploy-iphone.sh --host <iphone_ip> --scheme rootless
./scripts/logs-iphone.sh --host <iphone_ip> --all --scheme rootless
```
