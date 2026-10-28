#!/usr/bin/env bash
# Builds build/Tinycap.app: compiles with swiftc (universal arm64 + x86_64 in release),
# writes Info.plist, copies the icon and signs with the sandbox entitlements.
#
#   scripts/build-app.sh                 # release, universal, ad-hoc signed
#   CONFIG=debug scripts/build-app.sh    # debug, current arch only
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Ad-hoc signed builds get a new code signature on every build, so macOS asks for
# Screen Recording permission again. Sign with a stable identity to avoid that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-app.tinycap.Tinycap}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT="$ROOT/build"
MODCACHE="$OUT/ModuleCache"
APP="$OUT/Tinycap.app"

if [[ "$CONFIG" == "release" ]]; then
  ARCHS="${ARCHS:-arm64 x86_64}"
  OPT=(-O -whole-module-optimization)
else
  ARCHS="${ARCHS:-$(uname -m)}"
  OPT=(-Onone -g -DDEBUG)
fi

# Inside an already-sandboxed shell, the macro plugin server can't apply its own
# nested sandbox; set NESTED_SANDBOX=0 to let SwiftUI macros expand there.
if [[ "${NESTED_SANDBOX:-1}" == "0" ]]; then OPT+=(-disable-sandbox); fi

mkdir -p "$MODCACHE"
export CLANG_MODULE_CACHE_PATH="$MODCACHE"

# libvpx + libwebm for WebM export: always universal, cached after the first build.
env -u ARCHS "$ROOT/scripts/build-vpx.sh"
VENDOR="$ROOT/build/vendor"

binaries=()
for arch in $ARCHS; do
  OBJ="$OUT/$CONFIG/$arch"
  rm -rf "$OBJ" && mkdir -p "$OBJ"
  target="$arch-apple-macos15.0"
  echo "==> Compiling TinycapCore ($arch, $CONFIG)"
  xcrun swiftc -target "$target" -swift-version 6 "${OPT[@]}" -module-cache-path "$MODCACHE" \
    -parse-as-library -module-name TinycapCore \
    -emit-library -static -emit-module -emit-module-path "$OBJ/TinycapCore.swiftmodule" \
    -o "$OBJ/libTinycapCore.a" "$ROOT"/Sources/TinycapCore/*.swift

  echo "==> Compiling VPXBridge ($arch, $CONFIG)"
  xcrun clang++ -target "$target" -std=c++17 -O2 -fPIC -Wall -Wextra -Wno-unused-parameter \
    -I "$ROOT/Sources/VPXBridge/include" -I "$VENDOR/include" -I "$VENDOR/include/libwebm" \
    -c "$ROOT/Sources/VPXBridge/VPXBridge.cc" -o "$OBJ/VPXBridge.o"
  xcrun ar rcs "$OBJ/libVPXBridge.a" "$OBJ/VPXBridge.o"

  echo "==> Compiling Tinycap ($arch, $CONFIG)"
  find "$ROOT/Sources/Tinycap" -name '*.swift' -print0 | xargs -0 \
    xcrun swiftc -target "$target" -swift-version 6 "${OPT[@]}" -module-cache-path "$MODCACHE" \
      -module-name Tinycap -I "$OBJ" -L "$OBJ" -lTinycapCore \
      -I "$ROOT/Sources/VPXBridge/include" -lVPXBridge -L "$VENDOR/lib" -lvpx -lwebm -lc++ \
      -Xlinker -dead_strip \
      -o "$OBJ/Tinycap"
  binaries+=("$OBJ/Tinycap")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/Tinycap"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD_NUMBER)/$BUILD_NUMBER/" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: Resources/AppIcon.icns missing; run scripts/make-icon.sh" >&2
fi

echo "==> Signing ($SIGN_IDENTITY)"
sign_flags=(--force --entitlements "$ROOT/Resources/Tinycap.entitlements" --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && sign_flags+=(--options runtime --timestamp)
codesign "${sign_flags[@]}" "$APP"
codesign --verify --strict "$APP"

du -sh "$APP" | awk '{print "==> Built " $2 " (" $1 ")"}'
