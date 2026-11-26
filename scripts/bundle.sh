#!/bin/zsh
# Build release binary and wrap it in a minimal signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
# Universal binary: Apple silicon + Intel
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/IFork
APP=build/iFork.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iFork"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>iFork</string>
  <key>CFBundleDisplayName</key><string>iFork</string>
  <key>CFBundleIdentifier</key><string>dev.hari.ifork</string>
  <key>CFBundleExecutable</key><string>iFork</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>iFork receives files from your phone over Wi-Fi.</string>
  <key>NSBonjourServices</key><array><string>_ifork._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications && rm -rf ~/Applications/iFork.app && cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/iFork.app"
fi
# Zip for GitHub Releases
(cd build && rm -f iFork.zip && ditto -c -k --keepParent iFork.app iFork.zip)
echo "Built $APP and build/iFork.zip"
