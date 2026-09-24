#!/bin/zsh
# One-time: create a self-signed code-signing identity "Supervision Dev" in a
# dedicated keychain. build.sh signs with it so macOS permission grants
# (Accessibility, Calendar) survive rebuilds. Safe to re-run; skips existing pieces.
set -e
D=~/Library/Application\ Support/Supervision/signing
mkdir -p "$D"; cd "$D"
if [ ! -f cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
    -subj "/CN=Supervision Dev" -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature"
  openssl pkcs12 -export -out sd.p12 -inkey key.pem -in cert.pem -passout pass:supervision -legacy 2>/dev/null \
    || openssl pkcs12 -export -out sd.p12 -inkey key.pem -in cert.pem -passout pass:supervision
fi
KC=~/Library/Keychains/supervision.keychain-db
if [ ! -f "$KC" ]; then
  security create-keychain -p supervision "$KC"
  security set-keychain-settings "$KC"   # never auto-lock
  security import sd.p12 -k "$KC" -P supervision -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k supervision "$KC" >/dev/null
  security list-keychains -d user -s $(security list-keychains -d user | tr -d '" ') "$KC"
fi
security find-identity -p codesigning "$KC" | grep "Supervision Dev" && echo "Identity ready."
