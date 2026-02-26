#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IPHONE_HOST=""
IPHONE_USER="root"
IPHONE_PORT="22"
SCHEME="rootless"
SCHEME_INPUT="rootless"
CONFIG_PATH="${REPO_DIR}/proxyd-c/example-config.json"
SKIP_TWEAK=0
SKIP_DAEMON=0
SKIP_SBRELOAD=0

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy-iphone.sh --host <iphone_ip> [options]

Uploads and installs Theos packages + config JSON on a jailbroken iPhone.

Options:
  --host <ip/hostname>       iPhone host (required)
  --user <username>          SSH user (default: root)
  --port <ssh_port>          SSH port (default: 22)
  --scheme <roothide|rootless|rootful>
                             Jailbreak package scheme (default: rootless)
  --config <path>            Config JSON to upload (default: proxyd-c/example-config.json)
  --skip-tweak               Do not install tweak .deb
  --skip-daemon              Do not install proxyd-c .deb
  --skip-sbreload            Do not run sbreload after tweak install
  -h, --help                 Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      IPHONE_HOST="${2:-}"
      shift 2
      ;;
    --user)
      IPHONE_USER="${2:-}"
      shift 2
      ;;
    --port)
      IPHONE_PORT="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME_INPUT="${2:-}"
      SCHEME="${SCHEME_INPUT}"
      if [[ "${SCHEME}" == "roothide" ]]; then
        SCHEME="rootless"
      fi
      if [[ "${SCHEME}" != "rootless" && "${SCHEME}" != "rootful" ]]; then
        echo "Invalid scheme: ${SCHEME}" >&2
        exit 1
      fi
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --skip-tweak)
      SKIP_TWEAK=1
      shift
      ;;
    --skip-daemon)
      SKIP_DAEMON=1
      shift
      ;;
    --skip-sbreload)
      SKIP_SBRELOAD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -n "${IPHONE_HOST}" ]] || { echo "--host is required" >&2; usage; exit 1; }
[[ -f "${CONFIG_PATH}" ]] || { echo "Config not found: ${CONFIG_PATH}" >&2; exit 1; }

SSH_TARGET="${IPHONE_USER}@${IPHONE_HOST}"
SSH_BASE=(ssh -p "${IPHONE_PORT}" "${SSH_TARGET}")
SCP_BASE=(scp -P "${IPHONE_PORT}")
REMOTE_TMP="/var/tmp/lumina-proxy-deploy"
REMOTE_CONFIG="/var/mobile/Library/Preferences/com.project.lumina.proxyd.json"
JB_PREFIX=""
if [[ "${SCHEME}" == "rootless" ]]; then
  JB_PREFIX="/var/jb"
fi
PLIST_PATH="${JB_PREFIX}/Library/LaunchDaemons/com.project.lumina.proxyd.plist"

collect_latest_deb() {
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    return 1
  fi
  ls -1t "${dir}"/*.deb 2>/dev/null | head -n 1
}

DAEMON_DEB=""
TWEAK_DEB=""
if [[ "${SKIP_DAEMON}" -eq 0 ]]; then
  DAEMON_DEB="$(collect_latest_deb "${REPO_DIR}/proxyd-c/packages" || true)"
  [[ -n "${DAEMON_DEB}" ]] || { echo "No proxyd-c .deb found in ${REPO_DIR}/proxyd-c/packages" >&2; exit 1; }
fi
if [[ "${SKIP_TWEAK}" -eq 0 ]]; then
  TWEAK_DEB="$(collect_latest_deb "${REPO_DIR}/tweak/packages" || true)"
  [[ -n "${TWEAK_DEB}" ]] || { echo "No tweak .deb found in ${REPO_DIR}/tweak/packages" >&2; exit 1; }
fi

echo "[deploy] Target: ${SSH_TARGET}:${IPHONE_PORT}"
echo "[deploy] Scheme: ${SCHEME_INPUT} (effective: ${SCHEME})"
echo "[deploy] Config:  ${CONFIG_PATH}"
if [[ -n "${DAEMON_DEB}" ]]; then echo "[deploy] Daemon package: ${DAEMON_DEB}"; fi
if [[ -n "${TWEAK_DEB}" ]]; then echo "[deploy] Tweak package:  ${TWEAK_DEB}"; fi

echo "[deploy] Creating remote temp dir..."
"${SSH_BASE[@]}" "mkdir -p '${REMOTE_TMP}'"

echo "[deploy] Uploading config..."
"${SCP_BASE[@]}" "${CONFIG_PATH}" "${SSH_TARGET}:${REMOTE_TMP}/com.project.lumina.proxyd.json"

if [[ -n "${DAEMON_DEB}" ]]; then
  echo "[deploy] Uploading proxyd-c package..."
  "${SCP_BASE[@]}" "${DAEMON_DEB}" "${SSH_TARGET}:${REMOTE_TMP}/"
fi
if [[ -n "${TWEAK_DEB}" ]]; then
  echo "[deploy] Uploading tweak package..."
  "${SCP_BASE[@]}" "${TWEAK_DEB}" "${SSH_TARGET}:${REMOTE_TMP}/"
fi

read -r -d '' REMOTE_SCRIPT <<EOF || true
set -e
mkdir -p /var/mobile/Library/Preferences
install -m 0644 '${REMOTE_TMP}/com.project.lumina.proxyd.json' '${REMOTE_CONFIG}'
chown mobile:mobile '${REMOTE_CONFIG}' || true

DPKG_BIN=\$(command -v dpkg || true)
APT_BIN=\$(command -v apt-get || true)
if [ -x /var/jb/usr/bin/dpkg ]; then DPKG_BIN=/var/jb/usr/bin/dpkg; fi
if [ -x /var/jb/usr/bin/apt-get ]; then APT_BIN=/var/jb/usr/bin/apt-get; fi

if ls '${REMOTE_TMP}'/*.deb >/dev/null 2>&1; then
  if [ -z "\${DPKG_BIN}" ]; then
    echo "dpkg not found on device" >&2
    exit 1
  fi
  "\${DPKG_BIN}" -i '${REMOTE_TMP}'/*.deb || { [ -n "\${APT_BIN}" ] && "\${APT_BIN}" -f install -y; } || true
  "\${DPKG_BIN}" -i '${REMOTE_TMP}'/*.deb || true
fi

if [ -f '${PLIST_PATH}' ]; then
  launchctl bootout system/com.project.lumina.proxyd >/dev/null 2>&1 || true
  launchctl bootstrap system '${PLIST_PATH}' >/dev/null 2>&1 || true
  launchctl kickstart -k system/com.project.lumina.proxyd >/dev/null 2>&1 || true
fi
EOF

echo "[deploy] Installing packages and restarting daemon..."
"${SSH_BASE[@]}" "${REMOTE_SCRIPT}"

if [[ "${SKIP_TWEAK}" -eq 0 && "${SKIP_SBRELOAD}" -eq 0 ]]; then
  echo "[deploy] Reloading SpringBoard (sbreload)..."
  "${SSH_BASE[@]}" "if [ -x /var/jb/usr/bin/sbreload ]; then /var/jb/usr/bin/sbreload >/dev/null 2>&1; elif command -v sbreload >/dev/null 2>&1; then sbreload >/dev/null 2>&1; else killall -9 SpringBoard >/dev/null 2>&1 || true; fi"
fi

echo ""
echo "[deploy] Done."
echo "[deploy] Next (run from WSL):"
echo "  ./scripts/logs-iphone.sh --host ${IPHONE_HOST} --all --scheme ${SCHEME_INPUT}"
echo "[deploy] Then open Minecraft and join a Bedrock server."
