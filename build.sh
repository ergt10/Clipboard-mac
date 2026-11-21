#!/bin/bash
# Builds build/ClipNest.app (universal: arm64 + x86_64) and build/ClipNest.zip / .dmg.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ClipNest.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "build/ClipNest-$arch"
done
lipo -create build/ClipNest-arm64 build/ClipNest-x86_64 -output "$APP/Contents/MacOS/ClipNest"
rm build/ClipNest-arm64 build/ClipNest-x86_64
cp Info.plist "$APP/Contents/"

# App icon, rendered by the app itself.
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/ClipNest" --icon build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--release" ]]; then
  ditto -c -k --keepParent "$APP" build/ClipNest.zip
  STAGE=build/dmg && mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname ClipNest -srcfolder "$STAGE" -ov -format UDZO build/ClipNest.dmg >/dev/null
  rm -rf "$STAGE"
fi
echo "Built $APP"
