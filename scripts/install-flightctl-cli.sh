#!/usr/bin/env bash
set -euo pipefail

VER=1.3.0
BASE_URL="https://github.com/flightctl/flightctl/releases/download/v${VER}"

OS_RAW=$(uname -s)
case "$OS_RAW" in
  Darwin) OS=darwin ;;
  Linux) OS=linux ;;
  *)
    echo "unsupported OS: $OS_RAW" >&2
    exit 1
    ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *)
    echo "unsupported arch: $ARCH" >&2
    exit 1
    ;;
esac

ASSET_BASE="flightctl-${OS}-${ARCH}"
case "$OS" in
  darwin) ARCHIVE="${ASSET_BASE}.zip" ;;
  linux) ARCHIVE="${ASSET_BASE}.tar.gz" ;;
esac

DEST="${HOME}/.local/bin"
mkdir -p "$DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

download() {
  curl -fsSL "${BASE_URL}/${1}" -o "${TMP}/${1}"
}

download "$ARCHIVE"

case "$OS" in
  darwin)
    unzip -q "${TMP}/${ARCHIVE}" -d "$TMP"
    BIN="${TMP}/${ASSET_BASE}"
    ;;
  linux)
    tar -xzf "${TMP}/${ARCHIVE}" -C "$TMP"
    BIN="${TMP}/${ASSET_BASE}"
    ;;
esac

[[ -f "$BIN" ]] || { echo "binary not found in archive: ${ASSET_BASE}" >&2; exit 1; }

if curl -fsSL "${BASE_URL}/${ASSET_BASE}-sha256.txt" -o "${TMP}/${ASSET_BASE}-sha256.txt" 2>/dev/null; then
  expected=$(tr -d '[:space:]' < "${TMP}/${ASSET_BASE}-sha256.txt")
  if command -v sha256sum >/dev/null 2>&1; then
    computed=$(sha256sum "$BIN" | awk '{print $1}')
  else
    computed=$(shasum -a 256 "$BIN" | awk '{print $1}')
  fi
  if [[ "$computed" != "$expected" ]]; then
    echo "sha256 mismatch for ${ASSET_BASE}" >&2
    exit 1
  fi
fi

install -m 0755 "$BIN" "${DEST}/flightctl"
"${DEST}/flightctl" version
