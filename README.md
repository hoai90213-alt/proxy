# iOS (Jailbreak) Proxy Scaffold

This folder is a separate starting point for an iOS jailbreak-oriented proxy setup, inspired by the Android relay flow in this repository.

It does not port the Android app directly. Instead, it provides a clean scaffold for:

- `proxyd`: a local daemon (start/stop/status control API + web-command polling hook)
- `proxyd-c`: a no-Mac daemon variant (C/BSD sockets, WSL/Theos friendly)
- `tweak`: a Theos tweak project (UDP redirect hooks implemented; overlay future work)
- `launchd`: a sample launch daemon plist
- `web`: API contract notes for a web dashboard to toggle proxy remotely
- `scripts`: WSL build/deploy/log helpers for no-Mac workflow

## What Is Implemented

- `proxyd` (Swift): local control HTTP server + poller skeleton (`/status`, `/proxy/start`, `/proxy/stop`, `/proxy/toggle`)
- `proxyd-c` (C): local control HTTP server + UDP pass-through relay (single active client, IPv4 loopback)
- `tweak`: UDP redirect hooks (`connect` + `sendto`) for jailbreak testing

Additional implementation (no-Mac path):

- `proxyd-c` UDP pass-through relay (single active client, IPv4 loopback)
- `tweak` UDP redirect hooks (`connect` + `sendto`) for jailbreak testing

## What Is Not Implemented Yet

- Full Bedrock/RakNet-aware proxy logic (packet parsing/modification)
- Additional iOS socket hook coverage (e.g. `recvfrom`/`sendmsg`/edge cases)
- Overlay menu rendering inside Minecraft
- Secure command signing (only bearer-token placeholder is included)

## How This Maps To Android Repo Concepts

- Android `Services.kt` -> iOS `proxyd` daemon lifecycle
- Android `LunarisRelay` -> future UDP relay core in `proxyd`
- Android `RemoteLink` UI toggle -> web dashboard + daemon control API
- Android overlay/native (`Pixie`) -> future jailbreak tweak overlay

## Suggested Next Steps

1. Add signed command verification in `proxyd`/`proxyd-c` remote command flow
2. Expand `proxyd-c` relay coverage (IPv6 local bind, metrics, packet logging)
3. Extend tweak hook coverage for more Minecraft networking code paths
4. Add IPC between tweak and daemon (Darwin notification or local socket)

No-Mac workflow (recommended for Windows + WSL users):

1. Use `proxyd-c` instead of `proxyd`
2. Run `ios/external-proxy/scripts/wsl-setup.sh` (install build tools / optional Theos)
3. Build packages with `ios/external-proxy/scripts/build-all.sh --theos --scheme rootless`
4. Deploy to iPhone with `ios/external-proxy/scripts/deploy-iphone.sh`
5. Tail logs with `ios/external-proxy/scripts/logs-iphone.sh`

## Build Note

This repository now includes two daemon paths:

- `proxyd` (Swift) -> best on macOS
- `proxyd-c` (C) -> best for Windows + WSL + Theos users

The current Windows workspace still does not have `gcc/clang/make`, so local builds were not run here.

## Task Split (PC vs iPhone)

PC / WSL side (you can do from Windows + Ubuntu):

- Build `proxyd-c` and Theos packages
- Upload/install packages and config via SSH
- Tail daemon/tweak logs via SSH

iPhone side (manual actions you need to do):

- Ensure jailbreak + SSH access works (`root@iphone`)
- Run `sbreload` if prompted/fallback reboot/respring
- Open Minecraft and join a Bedrock server to generate logs
- Send back tweak + daemon logs if connection fails
