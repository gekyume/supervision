#!/bin/zsh
# Builds Supervision.app and supervisionctl into ./build. Run install.sh afterwards.
set -e
cd "$(dirname "$0")/.."
# Personal overrides (not published): e.g. BUNDLE_ID=com.yourname.supervision
[ -f scripts/local.env ] && source scripts/local.env
BUNDLE_ID=${BUNDLE_ID:-com.supervision.mac}
# Build outside the project: iCloud-synced folders (Desktop & Documents) stamp files with
# attributes that make codesign refuse the bundle. BUILD_DIR is local-only.
BUILD_DIR=${BUILD_DIR:-$HOME/Library/Caches/supervision-build}
mkdir -p "$BUILD_DIR"
# swiftc directly: SwiftPM needs full Xcode; the Command Line Tools are enough.
ARCH=$(uname -m)
swiftc -O -target $ARCH-apple-macos13.0 -framework AppKit -framework EventKit -framework CoreMediaIO -framework CoreAudio -framework AVFoundation -framework Vision -framework CoreVideo -lsqlite3 Sources/Shared/*.swift Sources/Supervision/*.swift -o "$BUILD_DIR/Supervision"
swiftc -O -target $ARCH-apple-macos13.0 -lsqlite3 Sources/Shared/*.swift Sources/cli/main.swift -o "$BUILD_DIR/supervisionctl"
APP="$BUILD_DIR/Supervision.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD_DIR/Supervision" "$APP/Contents/MacOS/Supervision"
cp docs/how-it-works.html "$APP/Contents/Resources/how-it-works.html"
cp Resources/*.png "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
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
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsUsageDescription</key><string>Supervision reads your meetings so it never interrupts a call, and writes an hourly Energy log.</string>
  <key>NSCameraUsageDescription</key><string>For your once-a-day progress photo, to count blinks during eye breaks, and to see your stretch. Nothing is recorded; the photo stays on this Mac.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Each morning Supervision saves your browser tab list and closes the tabs, so the day starts clean.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Supervision reads your meetings so it never interrupts a call, and writes an hourly Energy log.</string>
</dict></plist>
EOF
sed -i '' "s/BUNDLE_ID_PLACEHOLDER/$BUNDLE_ID/" "$APP/Contents/Info.plist"
# Sign with the stable self-signed "Supervision Dev" identity (kept in its own keychain,
# created once by scripts/make-signing-identity.sh). macOS ties Accessibility and
# Calendar grants to the signing certificate, so an ad-hoc signature would lose them
# on every rebuild. Falls back to ad-hoc if the identity is missing.
KC=~/Library/Keychains/supervision.keychain-db
# Extended attributes (e.g. from files opened in a browser) make codesign refuse the bundle.
xattr -cr "$APP"
if [ -f "$KC" ] && security unlock-keychain -p supervision "$KC" 2>/dev/null; then
  codesign --force --sign "Supervision Dev" --keychain "$KC" --identifier "$BUNDLE_ID" "$APP" 2>&1 | grep -v "replacing existing" || true
  # Fail loudly: a wrong signature silently drops macOS permissions (Accessibility, Calendar).
  codesign -dvv "$APP" 2>&1 | grep -q "Authority=Supervision Dev" || { echo "ERROR: signing failed; not installing a build that would lose permissions."; exit 1; }
else
  echo "warning: no Supervision Dev identity, signing ad-hoc (permissions will reset on rebuild)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1
fi
echo "Built $APP and $BUILD_DIR/supervisionctl"
