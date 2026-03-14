#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq
# Regenerates versions.json with the latest sql-pipe release.
# Used by nixpkgs' r-ryantm bot via passthru.updateScript, and can
# also be run manually:  ./update.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

REPO="vmvarela/sql-pipe"

VERSION=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" \
  | jq -r '.tag_name | ltrimstr("v")')

CHECKSUMS=$(curl -fsSL \
  "https://github.com/${REPO}/releases/download/v${VERSION}/sha256sums.txt")

get_sha() {
  echo "$CHECKSUMS" | awk -v asset="$1" '$2 == asset { print $1 }'
}

jq -n \
  --arg ver "$VERSION" \
  --arg sha_x64_linux  "$(get_sha sql-pipe-x86_64-linux)" \
  --arg sha_a64_linux  "$(get_sha sql-pipe-aarch64-linux)" \
  --arg sha_x64_macos  "$(get_sha sql-pipe-x86_64-macos)" \
  --arg sha_a64_macos  "$(get_sha sql-pipe-aarch64-macos)" \
  '{
    "x86_64-linux": {
      url:     "https://github.com/vmvarela/sql-pipe/releases/download/v\($ver)/sql-pipe-x86_64-linux",
      sha256:  $sha_x64_linux,
      version: $ver
    },
    "aarch64-linux": {
      url:     "https://github.com/vmvarela/sql-pipe/releases/download/v\($ver)/sql-pipe-aarch64-linux",
      sha256:  $sha_a64_linux,
      version: $ver
    },
    "x86_64-darwin": {
      url:     "https://github.com/vmvarela/sql-pipe/releases/download/v\($ver)/sql-pipe-x86_64-macos",
      sha256:  $sha_x64_macos,
      version: $ver
    },
    "aarch64-darwin": {
      url:     "https://github.com/vmvarela/sql-pipe/releases/download/v\($ver)/sql-pipe-aarch64-macos",
      sha256:  $sha_a64_macos,
      version: $ver
    }
  }' > versions.json

echo "Updated versions.json to ${VERSION}"
