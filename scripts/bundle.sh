#!/bin/zsh
# Builds Nav.app (menu-bar-less agent app) so macOS permissions are granted to "Nav", not the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Nav.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Nav "$APP/Contents/MacOS/Nav"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.adrian.nav</string>
    <key>CFBundleName</key><string>Nav</string>
    <key>CFBundleExecutable</key><string>Nav</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Nav reads your iTerm2 tabs so it can show and switch to them.</string>
</dict>
</plist>
PLIST
# Drop extended attributes: zipped, they turn into ._ files that break the signature.
xattr -cr "$APP"

# Sign with a real identity when available: ad-hoc signatures change on every
# build, which makes macOS forget the Screen Recording / Accessibility grants.
IDENTITY=${NAV_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
# Zip for distribution, without resource forks / extended attributes.
rm -f build/Nav.zip
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" build/Nav.zip
echo "Built $APP and build/Nav.zip"
