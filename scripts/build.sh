#!/bin/zsh
# Builds Supervision.app and supervisionctl into ./build. Run install.sh afterwards.
set -e
cd "$(dirname "$0")/.."
# Personal overrides (not published): e.g. BUNDLE_ID=com.yourname.supervision
[ -f scripts/local.env ] && source scripts/local.env
BUNDLE_ID=${BUNDLE_ID:-com.supervision.mac}
# swiftc directly: SwiftPM needs full Xcode, this Mac has only Command Line Tools.
mkdir -p build
ARCH=$(uname -m)
swiftc -O -target $ARCH-apple-macos13.0 -framework AppKit -framework EventKit -framework CoreMediaIO -framework CoreAudio -lsqlite3 Sources/Supervision/*.swift -o build/Supervision
swiftc -O -target $ARCH-apple-macos13.0 -lsqlite3 Sources/cli/main.swift -o build/supervisionctl
APP=build/Supervision.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/Supervision "$APP/Contents/MacOS/Supervision"
cp docs/how-it-works.html "$APP/Contents/Resources/how-it-works.html"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>BUNDLE_ID_PLACEHOLDER</string>
  <key>CFBundleName</key><string>Supervision</string>
  <key>CFBundleExecutable</key><string>Supervision</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsUsageDescription</key><string>Supervision reads your meetings so it never interrupts a call, and writes an hourly Energy log.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Supervision reads your meetings so it never interrupts a call, and writes an hourly Energy log.</string>
</dict></plist>
EOF
sed -i '' "s/BUNDLE_ID_PLACEHOLDER/$BUNDLE_ID/" "$APP/Contents/Info.plist"
# Sign with the stable self-signed "Supervision Dev" identity (kept in its own keychain,
# created once by scripts/make-signing-identity.sh). macOS ties Accessibility and
# Calendar grants to the signing certificate, so an ad-hoc signature would lose them
# on every rebuild. Falls back to ad-hoc if the identity is missing.
KC=~/Library/Keychains/supervision.keychain-db
if [ -f "$KC" ] && security unlock-keychain -p supervision "$KC" 2>/dev/null; then
  codesign --force --sign "Supervision Dev" --keychain "$KC" --identifier "$BUNDLE_ID" "$APP" 2>&1 | grep -v "replacing existing" || true
else
  echo "warning: no Supervision Dev identity, signing ad-hoc (permissions will reset on rebuild)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1
fi
echo "Built $APP and build/supervisionctl"
