#!/usr/bin/env bash
# Archive + export RayMol for App Store Connect (macOS or iOS).
# Usage: ./archive_appstore.sh [macOS|iOS]
# Requires: Xcode signed into the Apple Developer account (team VT99UQUQ89) so
# automatic Distribution signing can mint the io.raymol.RayMol profile.
set -euo pipefail
cd "$(dirname "$0")"

DEST="${1:-macOS}"
EXTRA_SETTINGS=()

if [ "$DEST" = "macOS" ]; then
  # Mac App Store build: Sparkle has no place here — self-update is disallowed on
  # the MAS, and its helper executables fail App Sandbox validation (error 90296).
  # Strip the Sparkle package + dependency from a transient copy of the spec
  # before generating, and compile the Sparkle + MCP code paths out of the build
  # via RAYMOL_MAS_RESTRICTED (gated in Swift by #if os(macOS) && !RAYMOL_MAS_RESTRICTED).
  # project.yml keeps Sparkle for the Developer-ID/DMG build (build.sh / make_dmg.sh);
  # only this App Store path removes it.
  cp project.yml project.yml.sparkle-bak
  trap 'mv -f project.yml.sparkle-bak project.yml 2>/dev/null || true' EXIT
  /usr/bin/sed -i '' '/# RAYMOL_SPARKLE_BEGIN/,/# RAYMOL_SPARKLE_END/d' project.yml
  if grep -q "package: Sparkle" project.yml; then
    echo "ERROR: Sparkle strip failed — RAYMOL_SPARKLE_BEGIN/END markers missing or moved in project.yml." >&2
    exit 1
  fi
  xcodegen generate
  mv -f project.yml.sparkle-bak project.yml
  trap - EXIT
  bash build_macos.sh
  SCHEME=PyMOLViewer_macOS
  DESTSPEC='generic/platform=macOS'
  EXTRA_SETTINGS=(SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RAYMOL_MAS_RESTRICTED')
elif [ "$DEST" = "iOS" ]; then
  xcodegen generate
  SCHEME=PyMOLViewer_iOS
  DESTSPEC='generic/platform=iOS'
else
  echo "usage: $0 [macOS|iOS]" >&2; exit 2
fi

ARCHIVE="build_archive/RayMol-$DEST.xcarchive"
xcodebuild -project PyMOLViewer.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination "$DESTSPEC" -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${EXTRA_SETTINGS[@]+"${EXTRA_SETTINGS[@]}"}" archive

OPTS="/tmp/raymol-export-$DEST.plist"
cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>VT99UQUQ89</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>export</string>
<!-- Skip symbol upload: the embedded third-party binaries (python-standalone,
     numpy, tcl, biopython) ship stripped with no DWARF, so dSYMs can't be
     produced for them and the upload "fails" 40x harmlessly. Our own code's
     symbols are irrelevant to App Store acceptance. (GUI Organizer: uncheck
     "Upload your app's symbols".) -->
<key>uploadSymbols</key><false/>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTS" -exportPath "build_export/$DEST" \
  -allowProvisioningUpdates

echo "=== exported to build_export/$DEST ==="
ls -la "build_export/$DEST"
