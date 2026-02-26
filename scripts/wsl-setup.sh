#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_THEOS=0
THEOS_DIR_DEFAULT="${HOME}/theos"
THEOS_DIR="${THEOS_DIR_DEFAULT}"

usage() {
  cat <<'EOF'
Usage: ./scripts/wsl-setup.sh [--install-theos] [--theos-dir <path>]

Installs common Ubuntu/WSL packages for this project and optionally clones Theos.

Options:
  --install-theos        Clone/update Theos into ~/theos (or --theos-dir)
  --theos-dir <path>     Custom Theos path
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-theos)
      INSTALL_THEOS=1
      shift
      ;;
    --theos-dir)
      THEOS_DIR="${2:-}"
      [[ -n "${THEOS_DIR}" ]] || { echo "Missing value for --theos-dir" >&2; exit 1; }
      shift 2
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

if [[ ! -f /etc/os-release ]]; then
  echo "This script is intended for Ubuntu/WSL." >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required." >&2
  exit 1
fi

echo "[wsl-setup] Installing Ubuntu packages..."
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  clang \
  make \
  git \
  curl \
  wget \
  ca-certificates \
  unzip \
  zip \
  xz-utils \
  python3 \
  python3-pip \
  rsync \
  openssh-client \
  dpkg-dev \
  fakeroot \
  file \
  jq

# ldid is optional on some Ubuntu versions/packages.
if apt-cache show ldid >/dev/null 2>&1; then
  sudo apt-get install -y ldid || true
fi

if [[ "${INSTALL_THEOS}" -eq 1 ]]; then
  echo "[wsl-setup] Installing Theos into ${THEOS_DIR}..."
  if [[ -d "${THEOS_DIR}/.git" ]]; then
    git -C "${THEOS_DIR}" pull --ff-only
    git -C "${THEOS_DIR}" submodule update --init --recursive
  else
    git clone --recursive https://github.com/theos/theos.git "${THEOS_DIR}"
  fi

  if ! grep -q 'export THEOS=' "${HOME}/.bashrc" 2>/dev/null; then
    {
      echo ""
      echo "# Added by Lumina external-proxy setup"
      echo "export THEOS=\"${THEOS_DIR}\""
      echo 'export PATH="$THEOS/bin:$PATH"'
    } >> "${HOME}/.bashrc"
    echo "[wsl-setup] Added THEOS env to ~/.bashrc"
  else
    echo "[wsl-setup] THEOS export already present in ~/.bashrc (left unchanged)"
  fi

  cat <<EOF

[wsl-setup] Theos installed.
Next manual requirement:
- Add an iPhone SDK under: ${THEOS_DIR}/sdks
  (Theos packaging may fail until SDK is present)
EOF
fi

echo ""
echo "[wsl-setup] Done."
echo "[wsl-setup] Repo: ${REPO_DIR}"
echo "[wsl-setup] Check tools:"
for cmd in make clang git ssh scp; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    echo "  - ${cmd}: OK ($(command -v "${cmd}"))"
  else
    echo "  - ${cmd}: MISSING"
  fi
done
