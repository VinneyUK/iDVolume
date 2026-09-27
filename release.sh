#!/bin/bash
# Builds a downloadable release: universal (Apple Silicon + Intel), signed, zipped.
#   ./release.sh            → dist/iDVolume-<version>.zip (+ .sha256)
# Signed with the self-signed "iDVolume Release" certificate (./make-signing-cert.sh) so
# every release has the same identity and macOS keeps the Accessibility permission across
# updates. (Not your Apple Development certificate: that would put your name/email in a
# public download.) Falls back to ad-hoc if the certificate doesn't exist.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

# Each release needs a new version number — the app only offers versions newer than its own.
# REPLACE=1 ./release.sh rebuilds an existing version on purpose (to replace its download).
if [ "${REPLACE:-0}" != "1" ] && { git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || \
   git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; }; then
  echo "✗ v$VERSION has already been released. Bump the version in Info.plist first, e.g.:"
  echo "    plutil -replace CFBundleShortVersionString -string <new> Info.plist"
  echo "  (or REPLACE=1 ./release.sh to deliberately rebuild v$VERSION)"
  exit 1
fi
echo "→ Releasing $VERSION"
if security find-identity -p codesigning 2>/dev/null | grep -q '"iDVolume Release"'; then
  RELEASE_IDENTITY="iDVolume Release"
else
  RELEASE_IDENTITY="-"
  echo "⚠ No \"iDVolume Release\" certificate — signing ad-hoc, so users will need to re-grant"
  echo "  Accessibility after this update. Run ./make-signing-cert.sh once to fix that."
fi
UNIVERSAL=1 CODESIGN_IDENTITY="$RELEASE_IDENTITY" ./build.sh

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
