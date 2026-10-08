#!/bin/sh
# Builds Lanes.app into ./build
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Lanes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Lanes "$APP/Contents/MacOS/Lanes"

# App icon
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift .build/icon_1024.png
for s in 16 32 128 256 512; do
    sips -z $s $s .build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) .build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Lanes</string>
    <key>CFBundleIdentifier</key><string>local.lanes</string>
    <key>CFBundleExecutable</key><string>Lanes</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
