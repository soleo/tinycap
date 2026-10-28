#!/usr/bin/env bash
# Runs the headless MP4 export check (Tests/ExportCheck): synthetic master → exports with
# trim, scale and both codecs → verifies duration, size, codec, file size and cancel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/export-check"
MODCACHE="$ROOT/build/ModuleCache"
TARGET="$(uname -m)-apple-macos15.0"
mkdir -p "$OUT" "$MODCACHE"
export CLANG_MODULE_CACHE_PATH="$MODCACHE"
EXTRA=()
if [[ "${NESTED_SANDBOX:-1}" == "0" ]]; then EXTRA+=(-disable-sandbox); fi

xcrun swiftc -target "$TARGET" -swift-version 6 -O -module-cache-path "$MODCACHE" "${EXTRA[@]}" \
  -parse-as-library -module-name TinycapCore \
  -emit-library -static -emit-module -emit-module-path "$OUT/TinycapCore.swiftmodule" \
  -o "$OUT/libTinycapCore.a" "$ROOT"/Sources/TinycapCore/*.swift

xcrun swiftc -target "$TARGET" -swift-version 6 -O -module-cache-path "$MODCACHE" "${EXTRA[@]}" \
  -parse-as-library -module-name ExportCheck -I "$OUT" -L "$OUT" -lTinycapCore \
  -o "$OUT/export-check" \
  "$ROOT/Sources/Tinycap/Export/Exporter.swift" "$ROOT/Sources/Tinycap/Export/MP4Exporter.swift" \
  "$ROOT/Tests/ExportCheck/main.swift"

"$OUT/export-check" "$OUT"
