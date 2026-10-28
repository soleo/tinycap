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

xcrun swiftc -target "$TARGET" -swift-version 6 -O -module-cache-path "$MODCACHE" ${EXTRA[@]+"${EXTRA[@]}"} \
  -parse-as-library -module-name TinycapCore \
  -emit-library -static -emit-module -emit-module-path "$OUT/TinycapCore.swiftmodule" \
  -o "$OUT/libTinycapCore.a" "$ROOT"/Sources/TinycapCore/*.swift

"$ROOT/scripts/build-vpx.sh"
VENDOR="$ROOT/build/vendor"
for f in VPXBridge/VPXBridge VPXInspect/VPXInspect; do
  xcrun clang++ -target "$TARGET" -std=c++17 -O2 -w -I "$ROOT/Sources/VPXBridge/include" -I "$VENDOR/include" -I "$VENDOR/include/libwebm" \
    -c "$ROOT/Sources/$f.cc" -o "$OUT/$(basename $f).o"
done
xcrun ar rcs "$OUT/libVPXCheck.a" "$OUT/VPXBridge.o" "$OUT/VPXInspect.o"

xcrun swiftc -target "$TARGET" -swift-version 6 -O -module-cache-path "$MODCACHE" ${EXTRA[@]+"${EXTRA[@]}"} \
  -parse-as-library -module-name ExportCheck -I "$OUT" -L "$OUT" -lTinycapCore \
  -I "$ROOT/Sources/VPXBridge/include" -lVPXCheck -L "$VENDOR/lib" -lvpx -lwebm -lc++ \
  -o "$OUT/export-check" \
  "$ROOT/Sources/Tinycap/Export/Exporter.swift" "$ROOT/Sources/Tinycap/Export/MP4Exporter.swift" \
  "$ROOT/Sources/Tinycap/Export/SizeEstimator.swift" "$ROOT/Sources/Tinycap/Export/GIFExporter.swift" \
  "$ROOT/Sources/Tinycap/Export/WebMExporter.swift" \
  "$ROOT/Tests/ExportCheck/main.swift"

"$OUT/export-check" "$OUT"
