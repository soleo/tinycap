#!/usr/bin/env bash
# Downloads the pinned Sparkle release (direct-download build's updater) into
# build/vendor/Sparkle and checks its SHA-256. Cached after the first run.
#
#   scripts/fetch-sparkle.sh
#
# Sparkle is MIT licensed: https://github.com/sparkle-project/Sparkle
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
DEST="$ROOT/build/vendor/Sparkle"
STAMP="$DEST/.version"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" && -d "$DEST/Sparkle.framework" ]]; then
  echo "==> Sparkle $VERSION up to date"
  exit 0
fi

echo "==> Downloading Sparkle $VERSION"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sparkle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/sparkle.tar.xz" "$URL"
actual="$(shasum -a 256 "$TMP/sparkle.tar.xz" | awk '{print $1}')"
if [[ "$actual" != "$SHA256" ]]; then
  echo "error: Sparkle checksum mismatch (expected $SHA256, got $actual)" >&2
  exit 1
fi

mkdir -p "$TMP/x"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP/x"
rm -rf "$DEST" && mkdir -p "$DEST"
# The framework, the signing tools for appcasts, and the license.
ditto "$TMP/x/Sparkle.framework" "$DEST/Sparkle.framework"
ditto "$TMP/x/bin" "$DEST/bin"
cp "$TMP/x/LICENSE" "$DEST/LICENSE"
echo "$VERSION" > "$STAMP"
echo "==> Sparkle $VERSION in $DEST"
