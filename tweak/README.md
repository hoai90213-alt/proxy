# Theos Tweak Placeholder

This folder is a placeholder for the jailbreak tweak that will eventually:

- Detect/load into Minecraft process
- Redirect network traffic to local `proxyd` (`127.0.0.1:<localProxyPort>`)
- (Optional) render overlay/menu in-game
- (Optional) communicate with `proxyd` for status/config

## Current State

- `Tweak.xm` only logs load-time startup (no hooks yet)
- `Makefile` is a minimal Theos skeleton

## Suggested Implementation Order

1. Confirm tweak loads in target process
2. Add local control client (`GET /status`)
3. Implement network redirection hook
4. Add overlay/menu
5. Add robust error handling and compatibility checks per Minecraft version

