# Theos Tweak (UDP Redirect)

This tweak redirects Minecraft Bedrock UDP traffic (default ports `19132/19133`) to the local `proxyd`/`proxyd-c` daemon on loopback.

It currently hooks:

- `connect` (UDP sockets)
- `sendto` (UDP datagrams)

Current limitation for `proxyd-c`:

- Redirect is effectively IPv4-focused right now (IPv6 redirect paths are disabled until `proxyd-c` gets IPv6 local bind support)

The redirect target is read from the proxyd JSON config:

- `/var/mobile/Library/Preferences/com.project.lumina.proxyd.json`

Supported tweak keys in that JSON (ignored by proxyd if unused):

- `tweakEnabled` (`true/false`)
- `rewritePorts` (array of destination ports to rewrite)
- `localProxyPort`

This folder still serves as the place for future jailbreak tweaks such as:

- Detect/load into Minecraft process
- (Optional) render overlay/menu in-game
- (Optional) communicate with `proxyd` for status/config

## Current State

- `Tweak.xm` contains UDP redirect hooks (`connect` + `sendto`)
- `Makefile` is a minimal Theos skeleton

## Suggested Implementation Order

1. Confirm tweak loads in target process
2. Verify UDP traffic is redirected to `127.0.0.1:<localProxyPort>`
3. Add local control client (`GET /status`) and optional on-screen state
4. Add compatibility guards per Minecraft version / symbol behavior
5. Add overlay/menu
6. Add more hooks if needed (`recvfrom` spoofing, `getpeername`, etc.)
