#!/bin/bash
# Builds build/iDVolume.app and build/idvol (CLI test tool). Needs Xcode or the Command Line Tools.
#   UNIVERSAL=1 ./build.sh          Apple Silicon + Intel in one app (used for releases)
#   CODESIGN_IDENTITY=- ./build.sh  force ad-hoc signing
set -euo pipefail
cd "$(dirname "$0")"

MIN="13.0"
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi
APP="build/iDVolume.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in $ARCHS; do
  echo "→ $ARCH: C / IOKit layer"
  clang -O2 -Wall -arch "$ARCH" -mmacosx-version-min="$MIN" -c Sources/AudientUSB.c -o "build/AudientUSB-$ARCH.o"

  echo "→ $ARCH: idvol CLI"
  clang -O2 -Wall -arch "$ARCH" -mmacosx-version-min="$MIN" Sources/idvol_cli.c "build/AudientUSB-$ARCH.o" \
    -framework IOKit -framework CoreFoundation -o "build/idvol-$ARCH"

  echo "→ $ARCH: Swift app"
  swiftc -O -parse-as-library -target "$ARCH-apple-macos$MIN" \
    -import-objc-header Sources/AudientUSB.h \
    Sources/*.swift "build/AudientUSB-$ARCH.o" \
    -framework IOKit -framework CoreFoundation -framework CoreAudio \
    -o "build/iDVolume-$ARCH"
done

# Combine the architectures into single binaries.
lipo -create build/iDVolume-* -output "$APP/Contents/MacOS/iDVolume"
lipo -create build/idvol-* -output build/idvol
rm -f build/iDVolume-* build/idvol-* build/AudientUSB-*.o
echo "→ Architectures: $(lipo -archs "$APP/Contents/MacOS/iDVolume")"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with a real identity if there is one, so macOS keeps the Accessibility
# grant across rebuilds. Ad-hoc ("-") works but loses the grant every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application|iDVolume/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
echo "→ Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP"
codesign --force --sign "$IDENTITY" build/idvol
[ "$IDENTITY" = "-" ] && echo "  (ad-hoc: re-grant Accessibility after each rebuild — see README)"

echo "✓ Built $APP"
echo "  Test first:  ./build/idvol        (detect)   ./build/idvol 0.2   (set speakers to 20%)"
echo "  Install:     cp -R $APP /Applications/ && open /Applications/iDVolume.app"
