#!/bin/sh

set -eu

REPO="vmvarela/sql-pipe"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

err() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || err "curl is required"

os_name=$(uname -s 2>/dev/null || true)
arch_name=$(uname -m 2>/dev/null || true)

case "$os_name" in
  Linux) os="linux" ;;
  Darwin) os="macos" ;;
  *) err "unsupported operating system: $os_name (supported: Linux, macOS)" ;;
esac

case "$arch_name" in
  x86_64|amd64) arch="x86_64" ;;
  aarch64|arm64) arch="aarch64" ;;
  *) err "unsupported architecture: $arch_name (supported: x86_64, aarch64)" ;;
esac

asset="sql-pipe-${arch}-${os}"
binary_url="https://github.com/${REPO}/releases/latest/download/${asset}"
checksums_url="https://github.com/${REPO}/releases/latest/download/sha256sums.txt"

tmp_bin=$(mktemp "${TMPDIR:-/tmp}/sql-pipe.bin.XXXXXX")
tmp_sums=$(mktemp "${TMPDIR:-/tmp}/sql-pipe.sha256.XXXXXX")
cleanup() {
  rm -f "$tmp_bin" "$tmp_sums"
}
trap cleanup EXIT INT TERM

printf '==> Downloading %s\n' "$asset"
curl -fsSL "$binary_url" -o "$tmp_bin" || err "failed to download binary from $binary_url"

printf '==> Downloading checksums\n'
curl -fsSL "$checksums_url" -o "$tmp_sums" || err "failed to download checksums from $checksums_url"

expected_hash=$(awk -v target="$asset" '$2 == target { print $1 }' "$tmp_sums")
[ -n "$expected_hash" ] || err "checksum for $asset not found in sha256sums.txt"

if command -v sha256sum >/dev/null 2>&1; then
  actual_hash=$(sha256sum "$tmp_bin" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
  actual_hash=$(shasum -a 256 "$tmp_bin" | awk '{ print $1 }')
elif command -v openssl >/dev/null 2>&1; then
  actual_hash=$(openssl dgst -sha256 "$tmp_bin" | awk '{ print $NF }')
else
  err "no SHA256 tool found (need sha256sum, shasum, or openssl)"
fi

[ "$expected_hash" = "$actual_hash" ] || err "checksum mismatch for $asset"

dest="${INSTALL_DIR%/}/sql-pipe"
mkdir -p "$INSTALL_DIR" || err "cannot create install directory: $INSTALL_DIR"

if install -m 0755 "$tmp_bin" "$dest" 2>/dev/null; then
  :
else
  cp "$tmp_bin" "$dest" 2>/dev/null || err "cannot write to $dest (try: sudo INSTALL_DIR=$INSTALL_DIR sh install.sh)"
  chmod 0755 "$dest" || err "cannot set executable permissions on $dest"
fi

printf '✅ Installed sql-pipe to %s\n' "$dest"
