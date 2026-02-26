# iOS (Jailbreak) Proxy Scaffold

This folder is a separate starting point for an iOS jailbreak-oriented proxy setup, inspired by the Android relay flow in this repository.

It does not port the Android app directly. Instead, it provides a clean scaffold for:

- `proxyd`: a local daemon (start/stop/status control API + web-command polling hook)
- `tweak`: a placeholder Theos tweak project (for future Minecraft traffic redirection / overlay)
- `launchd`: a sample launch daemon plist
- `web`: API contract notes for a web dashboard to toggle proxy remotely

## What Is Implemented

- Local control HTTP server skeleton (`/status`, `/proxy/start`, `/proxy/stop`, `/proxy/toggle`)
- In-memory proxy runtime state machine (stub, no UDP relay yet)
- Optional remote web command poller skeleton (for dashboard-triggered commands)
- Theos tweak placeholder (no hooks implemented)

## What Is Not Implemented Yet

- Actual Bedrock/RakNet UDP proxy forwarding
- Minecraft iOS socket/RakNet hook
- Overlay menu rendering inside Minecraft
- Secure command signing (only bearer-token placeholder is included)

## How This Maps To Android Repo Concepts

- Android `Services.kt` -> iOS `proxyd` daemon lifecycle
- Android `LunarisRelay` -> future UDP relay core in `proxyd`
- Android `RemoteLink` UI toggle -> web dashboard + daemon control API
- Android overlay/native (`Pixie`) -> future jailbreak tweak overlay

## Suggested Next Steps

1. Implement UDP pass-through relay in `ios/proxyd/Sources/LuminaProxyDaemon/ProxyRuntime.swift`
2. Add signed command verification in `WebCommandPoller.swift`
3. Implement Minecraft traffic redirection in `ios/tweak/Tweak.xm`
4. Add IPC between tweak and daemon (Darwin notification or local socket)

## Build Note

This is a scaffold only. It was created on a Windows workspace and was not compiled here.
Use macOS + Xcode / Swift toolchain + Theos on your jailbreak toolchain to continue.

