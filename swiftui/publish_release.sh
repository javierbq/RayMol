#!/bin/bash
# publish_release.sh — EdDSA-sign the notarized DMG, regenerate appcast.xml, and
# publish the DMG + appcast to GitHub Releases on javierbq/RayMol.
#
# Run AFTER make_dmg.sh has produced a notarized RayMol-<VERSION>.dmg at the repo
# root. The appcast feed served at
#   https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml
# is what installed RayMol.app polls (SUFeedURL in Info.plist).
#
# Usage:
#   VERSION=1.1.0 BUILD=5 bash swiftui/publish_release.sh
#
# VERSION = marketing version (CFBundleShortVersionString)
# BUILD   = CFBundleVersion (CURRENT_PROJECT_VERSION) — Sparkle compares on this,
#           so it MUST increase every release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="javierbq/RayMol"
VERSION="${VERSION:?Set VERSION, e.g. 1.1.0}"
BUILD="${BUILD:?Set BUILD (CFBundleVersion), e.g. 5}"
DMG="$ROOT/RayMol-$VERSION.dmg"
APPCAST="$ROOT/appcast.xml"

[ -f "$DMG" ] || { echo "ERROR: $DMG not found (run make_dmg.sh first)"; exit 1; }

# Sparkle's sign_update ships inside the resolved SPM artifact.
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*Sparkle/bin/sign_update' 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "ERROR: sign_update not found; run 'xcodebuild -resolvePackageDependencies' first"; exit 1; }

echo "== EdDSA-sign the DMG =="
# sign_update prints an attribute fragment, e.g.:
#   sparkle:edSignature="…" length="12345"
SIGFRAG="$("$SIGN_UPDATE" "$DMG")"
echo "  $SIGFRAG"

URL="https://github.com/$REPO/releases/download/v$VERSION/RayMol-$VERSION.dmg"
PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
NOTESLINK="https://github.com/$REPO/releases/tag/v$VERSION"

echo "== Write appcast.xml =="
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>RayMol</title>
    <link>https://github.com/$REPO/releases/latest/download/appcast.xml</link>
    <description>RayMol macOS updates</description>
    <language>en</language>
    <item>
      <title>RayMol $VERSION</title>
      <sparkle:releaseNotesLink>$NOTESLINK</sparkle:releaseNotesLink>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIGFRAG />
    </item>
  </channel>
</rss>
XML
echo "  wrote $APPCAST"

# Stable-named copy of the DMG so the website can link a FIXED url that always
# serves the newest release: https://github.com/$REPO/releases/latest/download/RayMol.dmg
# (the versioned RayMol-$VERSION.dmg name changes every release, so it can't be
# used with the /latest/ redirect). Same notarized+stapled bytes, second name.
STABLE_DMG="$ROOT/RayMol.dmg"
cp "$DMG" "$STABLE_DMG"

echo "== Publish GitHub release v$VERSION =="
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG" "$STABLE_DMG" "$APPCAST" -R "$REPO" --clobber
else
  if [ -n "${NOTES_FILE:-}" ]; then
    gh release create "v$VERSION" "$DMG" "$STABLE_DMG" "$APPCAST" -R "$REPO" \
      --title "RayMol $VERSION" --notes-file "$NOTES_FILE"
  else
    gh release create "v$VERSION" "$DMG" "$STABLE_DMG" "$APPCAST" -R "$REPO" \
      --title "RayMol $VERSION" \
      --notes "${NOTES:-Automatic updates are here. RayMol now checks for new versions and installs them with one click — no more manual DMG downloads. Built on the open-source PyMOL engine.}"
  fi
fi

echo "DONE → https://github.com/$REPO/releases/tag/v$VERSION"
