#!/bin/zsh
# Build WD19 Split.app (menu bar app) and the dockctl CLI into ./dist.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="dist/WD19 Split.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/WD19Split" "$APP/Contents/MacOS/WD19Split"
cp "$BIN/dockctl" dist/dockctl

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>WD19 Split</string>
	<key>CFBundleDisplayName</key><string>WD19 Split</string>
	<key>CFBundleIdentifier</key><string>local.wd19split</string>
	<key>CFBundleExecutable</key><string>WD19Split</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>Interoperability tool for the Dell WD19 dock.</string>
</dict>
</plist>
PLIST

# A stable identity keeps privacy grants (Screen Recording) across rebuilds;
# ad-hoc signing ("-") would invalidate them every build. Override with SIGN_ID.
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}
SIGN_ID=${SIGN_ID:--}
codesign --force --sign "$SIGN_ID" "$APP"
codesign --force --sign "$SIGN_ID" dist/dockctl
echo "signed with: $SIGN_ID"
echo "built: $APP and dist/dockctl"
