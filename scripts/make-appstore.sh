#!/usr/bin/env bash
# Builds the Mac App Store package:
#   1. universal release build with CHANNEL=appstore (no Sparkle, no network), signed with
#      your Apple Distribution certificate and the App Store provisioning profile
#   2. checks the bundle: universal, sandboxed, no network, no updater, profile embedded
#   3. a signed installer package for App Store Connect
#
#   SIGN_IDENTITY="Apple Distribution: Your Name (TEAMID)" \
#   INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)" \
#   PROVISIONING_PROFILE=~/path/Tinycap_App_Store.provisionprofile \
#   scripts/make-appstore.sh
#
# Upload build/appstore/Tinycap-<version>.pkg with Apple's Transporter app, then try it
# through TestFlight before submitting it for review. The build number (commit count)
# must be higher than the last upload's; set BUILD_NUMBER to re-upload the same commit.
#
# Other variables: VERSION (default: the VERSION file), BUILD_NUMBER (default: commit
# count), BUNDLE_ID, ALLOW_PORTABLE_VPX=1 to build without nasm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  "") ;;
  *) echo "error: unknown option $1" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-app.tinycap.Tinycap}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "VERSION must look like 1.2 or 1.2.3 (got '$VERSION')"

# --- Preflight -------------------------------------------------------------------
[[ -n "${SIGN_IDENTITY:-}" ]] || die "set SIGN_IDENTITY to your 'Apple Distribution: …' identity"
[[ "$SIGN_IDENTITY" == Apple\ Distribution:* || "$SIGN_IDENTITY" == 3rd\ Party\ Mac\ Developer\ Application:* ]] \
  || die "SIGN_IDENTITY must be an 'Apple Distribution' identity for the App Store (got '$SIGN_IDENTITY')"
[[ -n "${INSTALLER_IDENTITY:-}" ]] || die "set INSTALLER_IDENTITY to your '3rd Party Mac Developer Installer: …' identity"
[[ -n "${PROVISIONING_PROFILE:-}" && -f "$PROVISIONING_PROFILE" ]] \
  || die "set PROVISIONING_PROFILE to the downloaded 'Mac App Store Connect' profile"

# Capture first: `cmd | grep -q` under pipefail fails when grep exits before cmd finishes.
signing="$(security find-identity -v -p codesigning)"
[[ "$signing" == *"\"$SIGN_IDENTITY\""* ]] || die "identity not found in your keychain: $SIGN_IDENTITY"
all="$(security find-identity -v)"
[[ "$all" == *"\"$INSTALLER_IDENTITY\""* ]] || die "identity not found in your keychain: $INSTALLER_IDENTITY"

profile="$(mktemp "${TMPDIR:-/tmp}/tinycap-profile.XXXXXX")"
trap 'rm -f "$profile"' EXIT
security cms -D -i "$PROVISIONING_PROFILE" > "$profile" 2>/dev/null || die "can't read $PROVISIONING_PROFILE"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$profile" 2>/dev/null || true; }
[[ "$(plist Platform:0)" == OSX ]] || die "not a macOS profile: $PROVISIONING_PROFILE"
[[ -z "$(plist ProvisionedDevices)" ]] || die "that's a development profile; download the 'Mac App Store Connect' distribution profile"
team="$(plist TeamIdentifier:0)"
[[ "$(plist Entitlements:com.apple.application-identifier)" == "$team.$BUNDLE_ID" ]] \
  || die "the profile is for $(plist Entitlements:com.apple.application-identifier), not $team.$BUNDLE_ID"
[[ "$SIGN_IDENTITY" == *"($team)" && "$INSTALLER_IDENTITY" == *"($team)" ]] \
  || die "both identities must belong to team $team, the profile's team"
# ISO 8601, e.g. 2027-10-29T10:00:00Z
expires="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$profile" 2>/dev/null || true)"
# The app must be signed with a certificate the profile lists, or App Store Connect
# rejects the upload (ITMS-90284). Several certificates can share one name, so match by
# SHA-1 fingerprint and sign with the matching one.
profile_certs=()
for i in $(seq 0 20); do
  der="$(/usr/bin/plutil -extract "DeveloperCertificates.$i" raw -o - "$profile" 2>/dev/null)" || break
  profile_certs+=("$(printf '%s' "$der" | base64 -D | shasum -a 1 | awk '{print toupper($1)}')")
done
(( ${#profile_certs[@]} > 0 )) || die "the profile lists no certificates"
signing_hash=""
while read -r hash; do
  for cert in "${profile_certs[@]}"; do [[ "$hash" == "$cert" ]] && signing_hash="$hash"; done
done < <(printf '%s\n' "$signing" | awk -v name="\"$SIGN_IDENTITY\"" 'index($0, name) { print toupper($2) }')
[[ -n "$signing_hash" ]] || die "none of your '$SIGN_IDENTITY' certificates is in the profile (it has ${profile_certs[*]}).
  Edit the profile on developer.apple.com, select the certificate in your keychain, download it again."
if [[ -n "$expires" ]] && (( $(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expires" +%s 2>/dev/null || echo 0) < $(date +%s) )); then
  die "the provisioning profile expired on $expires; download a new one"
fi

if [[ "${ALLOW_PORTABLE_VPX:-0}" != "1" ]] && ! command -v nasm >/dev/null && ! command -v yasm >/dev/null; then
  die "nasm not found: the Intel build of libvpx would be slow. Run 'brew install nasm', or set ALLOW_PORTABLE_VPX=1"
fi
if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
  echo "warning: working tree has uncommitted changes; the package won't match a commit" >&2
fi

APP="$ROOT/build/Tinycap.app"
OUT="$ROOT/build/appstore"
PKG="$OUT/Tinycap-$VERSION.pkg"
mkdir -p "$OUT"

# --- 1. App ----------------------------------------------------------------------
step "Building Tinycap $VERSION ($BUILD_NUMBER) for the App Store, universal release"
echo "    signing with $SIGN_IDENTITY, certificate $signing_hash (in the profile)"
CHANNEL=appstore CONFIG=release VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" BUNDLE_ID="$BUNDLE_ID" \
  SIGN_IDENTITY="$signing_hash" PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  "$ROOT/scripts/build-app.sh"

# --- 2. Checks -------------------------------------------------------------------
step "Checking the bundle"
archs="$(xcrun lipo -archs "$APP/Contents/MacOS/Tinycap")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || die "expected a universal binary, got: $archs"
[[ ! -e "$APP/Contents/Frameworks/Sparkle.framework" ]] || die "Sparkle is in the App Store build"
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || die "no embedded provisioning profile"
[[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]] || die "no privacy manifest"
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
[[ "$entitlements" == *com.apple.security.app-sandbox* ]] || die "the app isn't sandboxed"
[[ "$entitlements" != *com.apple.security.network* ]] || die "the App Store build shouldn't have network access"
[[ "$entitlements" != *temporary-exception* ]] || die "temporary sandbox exceptions in the App Store build"
[[ "$entitlements" == *"$team.$BUNDLE_ID"* ]] || die "the signature doesn't carry the application identifier"
codesign --verify --strict --deep "$APP" || die "app signature doesn't verify"

# --- 3. Package ------------------------------------------------------------------
step "Creating $(basename "$PKG")"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG" >/dev/null \
  || die "productbuild couldn't create the package"
# Read the whole report before trimming it: cutting the pipe short makes pkgutil print
# "write: Permission denied". Packages signed for the App Store show as "(Development)"
# here, because only the App Store installs them.
# pkgutil can exit non-zero for a certificate this Mac doesn't trust for installs, so
# look for the installer certificate in its report instead.
signature="$(pkgutil --check-signature "$PKG" 2>&1 || true)"
[[ "$signature" == *"$INSTALLER_IDENTITY"* ]] || die "the package isn't signed with $INSTALLER_IDENTITY"
echo "$signature" | sed -n '2,4p'

SIZE="$(du -h "$PKG" | awk '{print $1}')"
echo
echo "==> $PKG ($SIZE), version $VERSION, build $BUILD_NUMBER"
echo
echo "Next:"
echo "  1. Open Transporter, drag in the package and click Deliver."
echo "  2. When App Store Connect has processed it (usually 10–30 minutes), install it from"
echo "     TestFlight and try a recording and a screenshot."
echo "  3. Pick the build on the App Store version page and submit it for review."
