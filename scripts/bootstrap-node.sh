#!/bin/bash
# Verified, private-to-Sona runtime. Does not modify the user's global Node.
set -euo pipefail
SONA_NODE_VERSION=24.20.0
SONA_NODE_SHA=40e5607e5ecb3db9192723776da2d75d966260fc74a7a9e731c1bd67dda96bc8
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "This bootstrap is for Apple silicon Macs. Use windows/scripts/install.ps1 on Windows." >&2
  exit 1
fi
SONA_NODE_CACHE="${SONA_CACHE_DIR:-$HOME/Library/Caches/Sona}/node-$SONA_NODE_VERSION"
SONA_NODE_DIST="node-v$SONA_NODE_VERSION-darwin-arm64"
mkdir -p "$SONA_NODE_CACHE"
SONA_NODE_ARCHIVE="$SONA_NODE_CACHE/$SONA_NODE_DIST.tar.gz"
if [ ! -f "$SONA_NODE_ARCHIVE" ]; then
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "https://nodejs.org/dist/v$SONA_NODE_VERSION/$SONA_NODE_DIST.tar.gz" -o "$SONA_NODE_ARCHIVE.partial"
  mv "$SONA_NODE_ARCHIVE.partial" "$SONA_NODE_ARCHIVE"
fi
if ! printf '%s  %s\n' "$SONA_NODE_SHA" "$SONA_NODE_ARCHIVE" | shasum -a 256 -c - >&2; then
  mv "$SONA_NODE_ARCHIVE" "$SONA_NODE_ARCHIVE.invalid-$(date +%s)"
  echo 'The download did not match its pinned checksum. It was quarantined. Run setup again to retry.' >&2
  exit 1
fi
if [ ! -x "$SONA_NODE_CACHE/$SONA_NODE_DIST/bin/node" ]; then
  tar -xzf "$SONA_NODE_ARCHIVE" -C "$SONA_NODE_CACHE"
fi
printf '%s\n' "$SONA_NODE_CACHE/$SONA_NODE_DIST"
