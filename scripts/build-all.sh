#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_THEOS=0
SCHEME=""

usage() {
  cat <<'EOF'
Usage: ./scripts/build-all.sh [--theos] [--scheme rootless|rootful]

Builds:
- proxyd-c Linux binary (always)
- Theos packages for proxyd-c and tweak (optional with --theos)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --theos)
      BUILD_THEOS=1
      shift
      ;;
    --scheme)
      SCHEME="${2:-}"
      if [[ "${SCHEME}" != "rootless" && "${SCHEME}" != "rootful" ]]; then
        echo "Invalid --scheme value: ${SCHEME}" >&2
        exit 1
      fi
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

echo "[build-all] Repo: ${REPO_DIR}"

echo "[build-all] Building proxyd-c (Linux/WSL)..."
make -C "${REPO_DIR}/proxyd-c" clean all

if [[ "${BUILD_THEOS}" -eq 0 ]]; then
  echo "[build-all] Skipping Theos packages (use --theos to enable)."
  exit 0
fi

if [[ -z "${THEOS:-}" || ! -d "${THEOS}" ]]; then
  echo "[build-all] THEOS is not set or path does not exist." >&2
  echo "[build-all] Run ./scripts/wsl-setup.sh --install-theos and re-open shell." >&2
  exit 1
fi

if [[ -n "${SCHEME}" ]]; then
  export THEOS_PACKAGE_SCHEME="${SCHEME}"
  echo "[build-all] Using THEOS_PACKAGE_SCHEME=${THEOS_PACKAGE_SCHEME}"
else
  echo "[build-all] Using default Theos package scheme"
fi

echo "[build-all] Building proxyd-c Theos package..."
make -C "${REPO_DIR}/proxyd-c" clean package

echo "[build-all] Building tweak Theos package..."
make -C "${REPO_DIR}/tweak" clean package

echo ""
echo "[build-all] Package outputs:"
find "${REPO_DIR}/proxyd-c/packages" -maxdepth 1 -type f -name '*.deb' -print 2>/dev/null || true
find "${REPO_DIR}/tweak/packages" -maxdepth 1 -type f -name '*.deb' -print 2>/dev/null || true
