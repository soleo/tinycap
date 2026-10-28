#!/usr/bin/env bash
# Builds the release DMG for direct download (GitHub Releases, Homebrew cask):
#   1. universal release build of Tinycap.app, signed with Developer ID + hardened runtime
#   2. DMG with the app and an Applications shortcut, signed
#   3. notarized with notarytool and stapled, so it opens offline without warnings
#   4. Gatekeeper check and SHA-256 (for the Homebrew cask)
#   5. Sparkle appcast.xml signed with the EdDSA key (scripts/make-appcast.sh)
#
# Release:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=tinycap-notary \
#   scripts/make-dmg.sh
#
# Local test DMG (ad-hoc signed, not notarized; Gatekeeper will warn on other Macs):
#   scripts/make-dmg.sh --unsigned
#
# One-time setup for notarization, stored in your login keychain (no secrets in files):
#   xcrun notarytool store-credentials tinycap-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#   (With 1Password: `op run -- xcrun notarytool store-credentials …` using op:// references.)
#
# Other variables: VERSION (default: the VERSION file), BUILD_NUMBER
# (default: commit count), BUNDLE_ID, ALLOW_PORTABLE_VPX=1 to release without nasm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNSIGNED=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "error: unknown option $arg" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

# --- Version -----------------------------------------------------------------
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "VERSION must look like 1.2 or 1.2.3 (got '$VERSION')"

# --- Preflight -------------------------------------------------------------------
if [[ "$UNSIGNED" == "1" ]]; then
  SIGN_IDENTITY="-"
  echo "warning: --unsigned: ad-hoc signed, not notarized. For local testing only." >&2
else
  [[ -n "${SIGN_IDENTITY:-}" ]] || die "set SIGN_IDENTITY to your 'Developer ID Application: …' identity (or use --unsigned)"
  [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]] \
    || die "SIGN_IDENTITY must be a 'Developer ID Application' identity for direct distribution (got '$SIGN_IDENTITY')"
  # Capture first: `cmd | grep -q` under pipefail fails when grep exits before cmd finishes.
  identities="$(security find-identity -v -p codesigning)"
  [[ "$identities" == *"\"$SIGN_IDENTITY\""* ]] || die "identity not found in your keychain: $SIGN_IDENTITY"
  [[ -s "$ROOT/Resources/sparkle-public-key.txt" ]] \
    || die "no Sparkle key: run scripts/make-appcast.sh --setup-key and commit Resources/sparkle-public-key.txt"
  [[ -n "${NOTARY_PROFILE:-}" ]] || die "set NOTARY_PROFILE to a notarytool keychain profile (see the header of this script)"
  if [[ "${ALLOW_PORTABLE_VPX:-0}" != "1" ]] && ! command -v nasm >/dev/null && ! command -v yasm >/dev/null; then
    die "nasm not found: the Intel build of libvpx would be slow. Run 'brew install nasm', or set ALLOW_PORTABLE_VPX=1"
  fi
  if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    echo "warning: working tree has uncommitted changes; the DMG won't match a commit" >&2
  fi
fi

OUT="$ROOT/build/release"
APP="$ROOT/build/Tinycap.app"
DMG="$OUT/Tinycap-$VERSION.dmg"
mkdir -p "$OUT"

# --- 1. App ----------------------------------------------------------------------
step "Building Tinycap $VERSION ($BUILD_NUMBER), universal release"
CHANNEL=direct CONFIG=release VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" SIGN_IDENTITY="$SIGN_IDENTITY" \
  "$ROOT/scripts/build-app.sh"

archs="$(xcrun lipo -archs "$APP/Contents/MacOS/Tinycap")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || die "expected a universal binary, got: $archs"
codesign --verify --strict --deep "$APP" || die "app signature doesn't verify"
if [[ "$UNSIGNED" == "0" ]]; then
  signature="$(codesign -d --verbose=2 "$APP" 2>&1)"
  [[ "$signature" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || die "hardened runtime is not enabled"
  team="$(echo "$SIGN_IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')"
  [[ "$signature" == *"TeamIdentifier=$team"* ]] || die "app isn't signed by team $team"
fi

# --- 2. DMG ----------------------------------------------------------------------
step "Creating $(basename "$DMG")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tinycap-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Tinycap.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
rm -f "$DMG"
hdiutil create -volname "Tinycap" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null \
  || die "hdiutil couldn't create the DMG"

if [[ "$UNSIGNED" == "0" ]]; then
  step "Signing the DMG"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

  # --- 3. Notarize ---------------------------------------------------------------
  step "Notarizing (usually 1–5 minutes)"
  submit_log="$OUT/notarize-$VERSION.json"
  if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$submit_log"; then
    cat "$submit_log" >&2
    die "notarization failed; details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
  fi
  status="$(/usr/bin/plutil -extract status raw -o - "$submit_log" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    id="$(/usr/bin/plutil -extract id raw -o - "$submit_log" 2>/dev/null || echo '<id>')"
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization status: ${status:-unknown}"
  fi
  step "Stapling the notarization ticket"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  # --- 4. Gatekeeper ---------------------------------------------------------------
  step "Checking with Gatekeeper"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "$SHA  $(basename "$DMG")" > "$DMG.sha256"
SIZE="$(du -h "$DMG" | awk '{print $1}')"

echo
echo "==> $DMG ($SIZE)"
echo "    sha256 $SHA"
if [[ "$UNSIGNED" == "0" ]]; then
  # --- 5. Appcast ------------------------------------------------------------------
  step "Signing the update feed"
  "$ROOT/scripts/make-appcast.sh" "$DMG" "$VERSION" "$BUILD_NUMBER"
  echo
  echo "Publish (the appcast must be on the latest release for the in-app updater):"
  notes="$ROOT/ReleaseNotes/$VERSION.md"
  if [[ -s "$notes" ]]; then notes_flag="--notes-file '$notes'"; else notes_flag="--generate-notes"; fi
  echo "  gh release create v$VERSION '$DMG' '$DMG.sha256' '$OUT/appcast.xml' --title 'Tinycap $VERSION' $notes_flag"
fi
