#!/bin/sh
# Compile Flocon.app dans ce dossier, en version universelle (puces Apple et Intel), pour macOS 13 et plus,
# puis lance le test. Usage : ./build.sh
set -e
cd "$(dirname "$0")"
APP=Flocon.app
VERSION=1.0
TMP=$(mktemp -d)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
for ARCH in arm64 x86_64; do
	swiftc -O -target "$ARCH-apple-macos13.0" main.swift -o "$TMP/Flocon-$ARCH"
done
lipo -create "$TMP/Flocon-arm64" "$TMP/Flocon-x86_64" -output "$APP/Contents/MacOS/Flocon"
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>app.flocon.mac</string>
	<key>CFBundleName</key><string>Flocon</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleExecutable</key><string>Flocon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
"$APP/Contents/MacOS/Flocon" --selftest
