#!/usr/bin/env bash
# Builds build/Tinycap.app: compiles with swiftc (universal arm64 + x86_64 in release),
# writes Info.plist, copies the icon and signs with the sandbox entitlements.
#
#   scripts/build-app.sh                 # release, universal, ad-hoc signed
#   CONFIG=debug scripts/build-app.sh    # debug, current arch only
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   CHANNEL=appstore scripts/build-app.sh   # App Store build: no Sparkle
#
# CHANNEL=direct (default) embeds Sparkle for in-place updates. Its EdDSA public key
# comes from Resources/sparkle-public-key.txt; without it the build has no updater
# and says so.
#
# Ad-hoc signed builds get a new code signature on every build, so macOS asks for
# Screen Recording permission again. Sign with a stable identity to avoid that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
# The marketing version lives in the VERSION file. The build number is the commit count,
# so it only grows; Sparkle compares it (CFBundleVersion) to decide what is newer.
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
# Shown in Settings → About. A "-dirty" suffix marks builds with uncommitted changes.
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_COMMIT="$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ "$GIT_COMMIT" != unknown ]] && [[ -n "$(git -C "$(dirname "$0")/.." status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi
BUNDLE_ID="${BUNDLE_ID:-app.tinycap.Tinycap}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
CHANNEL="${CHANNEL:-direct}"
[[ "$CHANNEL" == direct || "$CHANNEL" == appstore ]] || { echo "error: CHANNEL must be direct or appstore" >&2; exit 1; }
SPARKLE_KEY_FILE="$ROOT/Resources/sparkle-public-key.txt"
# The appcast is attached to each GitHub release; "latest" always points at the newest.
FEED_URL="${FEED_URL:-https://github.com/soleo/tinycap/releases/latest/download/appcast.xml}"
USE_SPARKLE=0
if [[ "$CHANNEL" == direct ]]; then
  if [[ -s "$SPARKLE_KEY_FILE" ]]; then
    USE_SPARKLE=1
  else
    echo "warning: $SPARKLE_KEY_FILE missing; building without the updater (see scripts/make-appcast.sh)" >&2
  fi
fi
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
SWIFT_EXTRA=()
[[ "$CHANNEL" == appstore ]] && SWIFT_EXTRA=(-DAPP_STORE)
if [[ "$USE_SPARKLE" == 1 ]]; then
  "$ROOT/scripts/fetch-sparkle.sh"
  SWIFT_EXTRA=(-DSPARKLE -F "$VENDOR/Sparkle" -framework Sparkle
               -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

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
      -Xlinker -dead_strip ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} \
      -o "$OBJ/Tinycap"
  binaries+=("$OBJ/Tinycap")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/Tinycap"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD_NUMBER)/$BUILD_NUMBER/" \
  -e "s/\$(BUILD_DATE)/$BUILD_DATE/" -e "s/\$(GIT_COMMIT)/$GIT_COMMIT/" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
if [[ "$USE_SPARKLE" == 1 ]]; then
  # Sparkle settings (direct build only). Checks are on by default (UP-5), so Sparkle's
  # "check automatically?" prompt is skipped; the Settings toggle turns them off.
  /usr/libexec/PlistBuddy \
    -c "Add :SUFeedURL string $FEED_URL" \
    -c "Add :SUPublicEDKey string $(tr -d '[:space:]' < "$SPARKLE_KEY_FILE")" \
    -c "Add :SUScheduledCheckInterval integer 86400" \
    -c "Add :SUEnableAutomaticChecks bool true" \
    -c "Add :SUAutomaticallyUpdate bool false" \
    -c "Add :SUAllowsAutomaticUpdates bool false" \
    -c "Add :SUEnableSystemProfiling bool false" \
    -c "Add :SUEnableInstallerLauncherService bool true" \
    "$PLIST"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: Resources/AppIcon.icns missing; run scripts/make-icon.sh" >&2
fi

ENTITLEMENTS="$ROOT/Resources/Tinycap.entitlements"
nested_flags=(--force --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && nested_flags+=(--options runtime --timestamp)

if [[ "$USE_SPARKLE" == 1 ]]; then
  echo "==> Embedding Sparkle"
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$VENDOR/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  # The app has network access itself, so Sparkle's downloader service isn't needed.
  rm -rf "$FW/XPCServices/Downloader.xpc"
  # Inside out, keeping each helper's own entitlements (Sparkle's sandboxing guide).
  codesign "${nested_flags[@]}" "$FW/XPCServices/Installer.xpc"
  codesign "${nested_flags[@]}" --preserve-metadata=entitlements "$FW/Autoupdate"
  codesign "${nested_flags[@]}" "$FW/Updater.app"
  codesign "${nested_flags[@]}" "$APP/Contents/Frameworks/Sparkle.framework"

  # The installer service is reached by mach name; the sandbox needs these exceptions.
  ENTITLEMENTS="$OUT/Tinycap-direct.entitlements"
  cp "$ROOT/Resources/Tinycap.entitlements" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name array" \
    -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $BUNDLE_ID-spks" \
    -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $BUNDLE_ID-spki" \
    "$ENTITLEMENTS"
fi

echo "==> Signing ($SIGN_IDENTITY, $CHANNEL$( [[ "$USE_SPARKLE" == 1 ]] && echo ", Sparkle" ))"
sign_flags=(--force --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && sign_flags+=(--options runtime --timestamp)
codesign "${sign_flags[@]}" "$APP"
codesign --verify --strict "$APP"

du -sh "$APP" | awk '{print "==> Built " $2 " (" $1 ")"}'
