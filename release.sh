#!/bin/bash
# Builds a downloadable release: universal (Apple Silicon + Intel), ad-hoc signed, zipped.
#   ./release.sh            → dist/iDVolume-<version>.zip (+ .sha256)
# Ad-hoc signing is deliberate: a personal "Apple Development" certificate is only for
# your own Macs, and it would embed your certificate name/email in a public download.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
UNIVERSAL=1 CODESIGN_IDENTITY=- ./build.sh

mkdir -p dist
ZIP="dist/iDVolume-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent build/iDVolume.app "$ZIP"      # ditto keeps the app bundle intact
(cd dist && shasum -a 256 "iDVolume-$VERSION.zip" > "iDVolume-$VERSION.zip.sha256")

echo
echo "✓ $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  Attach it to the release:"
echo "    gh release upload v$VERSION $ZIP $ZIP.sha256 --clobber"
echo "  (or create the release with it:  gh release create v$VERSION $ZIP $ZIP.sha256 --title \"iDVolume $VERSION\" --notes \"…\")"
