#!/usr/bin/env bash
# Points the Homebrew cask at a published release. Run after `gh release create`.
#
#   scripts/bump-cask.sh <path to a soleo/homebrew-tap checkout> [version]
#
# Version defaults to the VERSION file. The checksum comes from the release's
# .sha256 file on GitHub, so the cask matches what was actually published.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP="${1:?usage: bump-cask.sh <homebrew-tap dir> [version]}"
VERSION="${2:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
CASK="$TAP/Casks/tinycap.rb"
REPO="${REPO:-https://github.com/soleo/tinycap}"
[[ -f "$CASK" ]] || { echo "error: $CASK not found" >&2; exit 1; }

sha="$(curl -fsSL "$REPO/releases/download/v$VERSION/Tinycap-$VERSION.dmg.sha256" | awk '{print $1}')" \
  || { echo "error: no published checksum for v$VERSION; is the release out?" >&2; exit 1; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "error: unexpected checksum '$sha'" >&2; exit 1; }

sed -i '' -E \
  -e "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$sha\"/" "$CASK"
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$sha\"" "$CASK" \
  || { echo "error: couldn't update $CASK" >&2; exit 1; }

echo "==> $CASK: $VERSION ($sha)"
echo "Check and publish:"
echo "  brew audit --cask --online soleo/tap/tinycap"
echo "  git -C '$TAP' commit -am 'tinycap $VERSION' && git -C '$TAP' push"
