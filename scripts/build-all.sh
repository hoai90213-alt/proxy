#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROXYD_C_DIR="${REPO_DIR}/proxyd-c"
TWEAK_DIR="${REPO_DIR}/tweak"

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

ensure_theos_toolchain_linux() {
  local toolchain_clang="${THEOS}/toolchain/linux/iphone/bin/clang"
  local arch
  local url=""

  if [[ -x "${toolchain_clang}" ]]; then
    return 0
  fi

  if [[ "$(uname -s)" != "Linux" ]]; then
    return 0
  fi

  arch="$(uname -m)"
  case "${arch}" in
    x86_64|aarch64)
      url="https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-${arch}.tar.xz"
      ;;
    *)
      echo "[build-all] Missing Theos iPhone toolchain and unsupported host arch: ${arch}" >&2
      return 1
      ;;
  esac

  echo "[build-all] Theos iPhone toolchain not found. Installing prebuilt toolchain for ${arch}..."
  mkdir -p "${THEOS}/toolchain"
  if ! command -v curl >/dev/null 2>&1; then
    echo "[build-all] curl is required to install Theos toolchain." >&2
    return 1
  fi

  curl -sL "${url}" | tar -xJf - -C "${THEOS}/toolchain/"

  if [[ ! -x "${toolchain_clang}" ]]; then
    echo "[build-all] Toolchain install completed but clang still missing: ${toolchain_clang}" >&2
    return 1
  fi

  echo "[build-all] Theos iPhone toolchain installed."
}

theos_build_in_temp_required() {
  [[ "$(uname -s)" == "Linux" ]] || return 1
  [[ "${REPO_DIR}" == /mnt/* ]]
}

sync_theos_project_to_temp() {
  local src="$1"
  local dst="$2"
  mkdir -p "${dst}"
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.theos' \
    --exclude 'packages' \
    --exclude 'obj' \
    --exclude 'luminaproxyd' \
    "${src}/" "${dst}/"
}

copy_debs_back() {
  local src_dir="$1/packages"
  local dst_dir="$2/packages"
  mkdir -p "${dst_dir}"
  if compgen -G "${src_dir}/*.deb" > /dev/null; then
    cp -f "${src_dir}"/*.deb "${dst_dir}/"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --theos)
      BUILD_THEOS=1
      shift
      ;;
    --scheme)
      SCHEME="${2:-}"
      if [[ "${SCHEME}" == "roothide" ]]; then
        echo "[build-all] Scheme 'roothide' detected -> using Theos rootless packaging"
        SCHEME="rootless"
      fi
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
make -C "${PROXYD_C_DIR}" clean all

if [[ "${BUILD_THEOS}" -eq 0 ]]; then
  echo "[build-all] Skipping Theos packages (use --theos to enable)."
  exit 0
fi

if [[ -z "${THEOS:-}" && -d "${HOME}/theos" ]]; then
  export THEOS="${HOME}/theos"
  echo "[build-all] Auto-detected THEOS=${THEOS}"
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

ensure_theos_toolchain_linux

echo "[build-all] Building proxyd-c Theos package..."
if theos_build_in_temp_required; then
  TMP_BUILD_ROOT="$(mktemp -d /tmp/lumina-external-proxy-build.XXXXXX)"
  trap 'rm -rf "${TMP_BUILD_ROOT:-}"' EXIT
  echo "[build-all] Detected /mnt path. Packaging in Linux temp dir: ${TMP_BUILD_ROOT}"

  sync_theos_project_to_temp "${PROXYD_C_DIR}" "${TMP_BUILD_ROOT}/proxyd-c"
  sync_theos_project_to_temp "${TWEAK_DIR}" "${TMP_BUILD_ROOT}/tweak"

  make -C "${TMP_BUILD_ROOT}/proxyd-c" clean package

  echo "[build-all] Building tweak Theos package..."
  make -C "${TMP_BUILD_ROOT}/tweak" clean package

  copy_debs_back "${TMP_BUILD_ROOT}/proxyd-c" "${PROXYD_C_DIR}"
  copy_debs_back "${TMP_BUILD_ROOT}/tweak" "${TWEAK_DIR}"
else
  make -C "${PROXYD_C_DIR}" clean package

  echo "[build-all] Building tweak Theos package..."
  make -C "${TWEAK_DIR}" clean package
fi

echo ""
echo "[build-all] Package outputs:"
find "${PROXYD_C_DIR}/packages" -maxdepth 1 -type f -name '*.deb' -print 2>/dev/null || true
find "${TWEAK_DIR}/packages" -maxdepth 1 -type f -name '*.deb' -print 2>/dev/null || true
