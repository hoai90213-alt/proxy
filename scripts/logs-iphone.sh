#!/usr/bin/env bash
set -euo pipefail

IPHONE_HOST=""
IPHONE_USER="root"
IPHONE_PORT="22"
SCHEME="rootless"
SHOW_DAEMON=0
SHOW_TWEAK=0
SHOW_ALL=0

usage() {
  cat <<'EOF'
Usage: ./scripts/logs-iphone.sh --host <iphone_ip> [--daemon|--tweak|--all]

Streams logs over SSH from a jailbroken iPhone.

Modes:
  --daemon   Tail proxyd daemon logs (/var/log/luminaproxyd*.log)
  --tweak    Stream unified logs filtered for LuminaProxyTweak
  --all      Show helper commands for both (recommended on Windows/WSL)

Options:
  --host <ip/hostname>       iPhone host (required)
  --user <username>          SSH user (default: root)
  --port <ssh_port>          SSH port (default: 22)
  --scheme <rootless|rootful> Used only for helper output (default: rootless)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) IPHONE_HOST="${2:-}"; shift 2 ;;
    --user) IPHONE_USER="${2:-}"; shift 2 ;;
    --port) IPHONE_PORT="${2:-}"; shift 2 ;;
    --scheme)
      SCHEME="${2:-}"
      [[ "${SCHEME}" == "rootless" || "${SCHEME}" == "rootful" ]] || { echo "Invalid --scheme" >&2; exit 1; }
      shift 2
      ;;
    --daemon) SHOW_DAEMON=1; shift ;;
    --tweak) SHOW_TWEAK=1; shift ;;
    --all) SHOW_ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "${IPHONE_HOST}" ]] || { echo "--host is required" >&2; usage; exit 1; }

if [[ "${SHOW_DAEMON}" -eq 0 && "${SHOW_TWEAK}" -eq 0 && "${SHOW_ALL}" -eq 0 ]]; then
  SHOW_ALL=1
fi

SSH_TARGET="${IPHONE_USER}@${IPHONE_HOST}"
SSH_BASE=(ssh -p "${IPHONE_PORT}" "${SSH_TARGET}")
JB_PREFIX=""
if [[ "${SCHEME}" == "rootless" ]]; then
  JB_PREFIX="/var/jb"
fi

if [[ "${SHOW_ALL}" -eq 1 ]]; then
  cat <<EOF
[logs] Use one of these (open 2 terminals if possible):

Daemon logs:
  ./scripts/logs-iphone.sh --host ${IPHONE_HOST} --daemon --scheme ${SCHEME}

Tweak logs:
  ./scripts/logs-iphone.sh --host ${IPHONE_HOST} --tweak --scheme ${SCHEME}

Quick health check:
  ssh -p ${IPHONE_PORT} ${SSH_TARGET} "launchctl print system/com.project.lumina.proxyd | head -n 20"
  ssh -p ${IPHONE_PORT} ${SSH_TARGET} "ls -l ${JB_PREFIX}/usr/bin/luminaproxyd 2>/dev/null || ls -l /usr/bin/luminaproxyd"
EOF
  exit 0
fi

if [[ "${SHOW_DAEMON}" -eq 1 ]]; then
  echo "[logs] Tailing proxyd logs on ${SSH_TARGET}..."
  exec "${SSH_BASE[@]}" "touch /var/log/luminaproxyd.log /var/log/luminaproxyd.err.log; tail -F /var/log/luminaproxyd.log /var/log/luminaproxyd.err.log"
fi

if [[ "${SHOW_TWEAK}" -eq 1 ]]; then
  echo "[logs] Streaming LuminaProxyTweak logs on ${SSH_TARGET}..."
  exec "${SSH_BASE[@]}" "log stream --style compact --predicate 'eventMessage CONTAINS[c] \"LuminaProxyTweak\"' 2>/dev/null || log show --last 5m --style compact --predicate 'eventMessage CONTAINS[c] \"LuminaProxyTweak\"'"
fi
