#!/bin/zsh
# Installs Supervision.app to ~/Applications, supervisionctl to /usr/local/bin (or ~/bin),
# and a launchd agent that starts it at login and relaunches it if it ever exits.
set -e
cd "$(dirname "$0")/.."
[ -f scripts/local.env ] && source scripts/local.env
BUNDLE_ID=${BUNDLE_ID:-com.supervision.mac}
BUILD_DIR=${BUILD_DIR:-$HOME/Library/Caches/supervision-build}
# Refuse to install a build with the wrong signature (it would silently drop macOS permissions).
if security find-identity -p codesigning ~/Library/Keychains/supervision.keychain-db 2>/dev/null | grep -q "Supervision Dev"; then
  codesign -dvv "$BUILD_DIR/Supervision.app" 2>&1 | grep -q "Authority=Supervision Dev" || { echo "ERROR: build is not signed with Supervision Dev; run scripts/build.sh again."; exit 1; }
fi
mkdir -p ~/Applications
rm -rf ~/Applications/Supervision.app
ditto --norsrc --noextattr "$BUILD_DIR/Supervision.app" ~/Applications/Supervision.app
if [ -w /usr/local/bin ]; then cp "$BUILD_DIR/supervisionctl" /usr/local/bin/supervisionctl; else mkdir -p ~/bin; cp "$BUILD_DIR/supervisionctl" ~/bin/supervisionctl; fi
PLIST=~/Library/LaunchAgents/$BUNDLE_ID.plist
mkdir -p ~/Library/LaunchAgents
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/Supervision.app/Contents/MacOS/Supervision</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>3</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Application Support/Supervision/supervision.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Application Support/Supervision/supervision.log</string>
</dict></plist>
EOF
launchctl bootout gui/$(id -u)/$BUNDLE_ID 2>/dev/null || true
sleep 2  # launchd needs a moment after bootout, or bootstrap fails with I/O error 5
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "Installed. Supervision is running and will relaunch itself."
