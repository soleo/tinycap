#!/usr/bin/env bash
# Builds TinycapCore and its XCTest bundle with swiftc directly and runs the tests.
# Equivalent to `swift test`, but works where the SwiftPM build service can't run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/test"
MODCACHE="$ROOT/build/ModuleCache"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos15.0"
PLATFORM="$(xcrun --show-sdk-platform-path 2>/dev/null)"
FRAMEWORKS="$PLATFORM/Developer/Library/Frameworks"
USRLIB="$PLATFORM/Developer/usr/lib"

rm -rf "$OUT" && mkdir -p "$OUT" "$MODCACHE"
export CLANG_MODULE_CACHE_PATH="$MODCACHE"

xcrun swiftc -target "$TARGET" -swift-version 6 -module-cache-path "$MODCACHE" \
  -parse-as-library -enable-testing -module-name TinycapCore \
  -emit-library -static -emit-module -emit-module-path "$OUT/TinycapCore.swiftmodule" \
  -o "$OUT/libTinycapCore.a" "$ROOT"/Sources/TinycapCore/*.swift

BUNDLE="$OUT/TinycapCoreTests.xctest"
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.tinycap.TinycapCoreTests</string>
<key>CFBundleExecutable</key><string>TinycapCoreTests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST

xcrun swiftc -target "$TARGET" -swift-version 6 -module-cache-path "$MODCACHE" \
  -parse-as-library -module-name TinycapCoreTests \
  -I "$OUT" -L "$OUT" -lTinycapCore \
  -F "$FRAMEWORKS" -I "$USRLIB" -L "$USRLIB" -framework XCTest \
  -Xlinker -bundle -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$USRLIB" \
  -o "$BUNDLE/Contents/MacOS/TinycapCoreTests" "$ROOT"/Tests/TinycapCoreTests/*.swift

xcrun xctest "$BUNDLE"

# WebM bridge: encode synthetic frames with libvpx/libwebm, then parse and decode them.
"$ROOT/scripts/build-vpx.sh"
VENDOR="$ROOT/build/vendor"
BRIDGE_FLAGS=(-std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -I "$ROOT/Sources/VPXBridge/include"
              -I "$VENDOR/include" -I "$VENDOR/include/libwebm")
xcrun clang++ "${BRIDGE_FLAGS[@]}" -c "$ROOT/Sources/VPXBridge/VPXBridge.cc" -o "$OUT/VPXBridge.o"
xcrun clang++ "${BRIDGE_FLAGS[@]}" -c "$ROOT/Sources/VPXInspect/VPXInspect.cc" -o "$OUT/VPXInspect.o"
xcrun clang -O2 -Wall -I "$ROOT/Sources/VPXBridge/include" -c "$ROOT/Tests/VPXBridgeTests/main.c" -o "$OUT/vpx-main.o"
xcrun clang++ "$OUT/VPXBridge.o" "$OUT/VPXInspect.o" "$OUT/vpx-main.o" -L "$VENDOR/lib" -lvpx -lwebm \
  -o "$OUT/vpxbridge-test"
echo "VPXBridge round trip"
"$OUT/vpxbridge-test" "$OUT/vpxbridge-test.webm"
