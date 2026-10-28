#!/usr/bin/env bash
# Sparkle appcast for the direct-download build.
#
#   scripts/make-appcast.sh --setup-key
#       One time: creates the EdDSA signing key in your login keychain (Sparkle's
#       generate_keys) and writes the public half to Resources/sparkle-public-key.txt.
#       Commit that file. The private key never leaves the keychain; back it up with
#       `generate_keys -x <file>` and store it in 1Password.
#
#   scripts/make-appcast.sh <dmg> <version> <build-number> [notes.md]
#       Signs the DMG with that key and writes appcast.xml next to it. Attach both to
#       the GitHub release tagged v<version>; the app reads
#       https://github.com/soleo/tinycap/releases/latest/download/appcast.xml.
#
#       Release notes (default ReleaseNotes/<version>.md) are converted to HTML
#       (scripts/notes-to-html.pl) and embedded, so the update window shows just the notes. Use the same file for the GitHub
#       release: gh release create … --notes-file ReleaseNotes/<version>.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/fetch-sparkle.sh" >/dev/null
BIN="$ROOT/build/vendor/Sparkle/bin"
KEY_FILE="$ROOT/Resources/sparkle-public-key.txt"
REPO="${REPO:-https://github.com/soleo/tinycap}"

if [[ "${1:-}" == "--setup-key" ]]; then
  # Prints the existing key if there is one; creates it otherwise.
  if ! "$BIN/generate_keys" -p >/dev/null 2>&1; then
    "$BIN/generate_keys"
  fi
  "$BIN/generate_keys" -p | tr -d '[:space:]' > "$KEY_FILE"
  echo "==> Public key written to $KEY_FILE: $(cat "$KEY_FILE")"
  exit 0
fi

DMG="${1:?usage: make-appcast.sh <dmg> <version> <build-number> | --setup-key}"
VERSION="${2:?version}"
BUILD_NUMBER="${3:?build number}"
NOTES="${4:-$ROOT/ReleaseNotes/$VERSION.md}"
[[ -s "$KEY_FILE" ]] || { echo "error: $KEY_FILE missing; run scripts/make-appcast.sh --setup-key" >&2; exit 1; }

# sign_update prints: sparkle:edSignature="…" length="…"
attrs="$("$BIN/sign_update" "$DMG")"
[[ "$attrs" == *edSignature=* ]] || { echo "error: sign_update failed: $attrs" >&2; exit 1; }

if [[ -s "$NOTES" ]]; then
  # HTML, because Sparkle runs Markdown notes together into one paragraph. Embedded
  # notes replace the releaseNotesLink, so only one source is given.
  html="$(perl "$ROOT/scripts/notes-to-html.pl" "$NOTES")"
  [[ "$html" == *']]>'* ]] && { echo "error: $NOTES contains ']]>', which would end the CDATA block" >&2; exit 1; }
  NOTES_XML="<description sparkle:descriptionFormat=\"html\"><![CDATA[
$html
]]></description>"
else
  echo "warning: $NOTES not found; the update window will show the GitHub release page" >&2
  NOTES_XML="<sparkle:releaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>"
fi

NAME="$(basename "$DMG")"
OUT="$(dirname "$DMG")/appcast.xml"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tinycap</title>
    <link>$REPO</link>
    <item>
      <title>Tinycap $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      $NOTES_XML
      <enclosure url="$REPO/releases/download/v$VERSION/$NAME" type="application/octet-stream" $attrs/>
    </item>
  </channel>
</rss>
XML
echo "==> $OUT"
