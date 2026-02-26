# Scripts (Windows + WSL + iPhone)

These scripts are for the no-Mac workflow using `proxyd-c` + Theos tweak.

What each script does:

- `wsl-setup.sh`: install common build tools in Ubuntu/WSL and optionally clone Theos
- `build-all.sh`: build `proxyd-c` (Linux) and optionally package `proxyd-c` + `tweak` with Theos
- `deploy-iphone.sh`: upload/install `.deb` packages + config JSON to a jailbroken iPhone over SSH
- `logs-iphone.sh`: tail `proxyd` logs and/or stream tweak logs over SSH

## Typical flow

1. Run `wsl-setup.sh` in Ubuntu/WSL
2. Configure `proxyd-c/example-config.json`
3. Run `build-all.sh --theos --scheme rootless` (or `rootful`)
4. Run `deploy-iphone.sh --host <iphone_ip> --scheme rootless`
5. Run `logs-iphone.sh --host <iphone_ip> --all`

## Important notes

- `deploy-iphone.sh` expects SSH access to the iPhone (`root@<ip>`)
- Theos packaging still requires a valid iPhone SDK in your Theos setup
- `proxyd-c` is UDP pass-through only (not Bedrock protocol-aware yet)
