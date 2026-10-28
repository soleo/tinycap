#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns and Resources/AppIcon-1024.png from the
# reference artwork. Default source: ../TinyCapIcon.png (workspace root).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/../TinyCapIcon.png}"
WORK="$ROOT/build/icon"
MODCACHE="$ROOT/build/ModuleCache"
rm -rf "$WORK" && mkdir -p "$WORK" "$MODCACHE"
export CLANG_MODULE_CACHE_PATH="$MODCACHE"

xcrun swiftc -O -module-cache-path "$MODCACHE" "$ROOT/scripts/make-icon.swift" -o "$WORK/make-icon"
"$WORK/make-icon" "$SRC" "$ROOT/Resources/AppIcon-1024.png" "$ROOT/Resources/AppIcon.icns" "$WORK/preview-dark.png"
ls -lh "$ROOT/Resources/AppIcon.icns" | awk '{print "==> Resources/AppIcon.icns (" $5 ")"}'
