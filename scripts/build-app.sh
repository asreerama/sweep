#!/bin/bash
# Build Sweep.app bundle (local profile) and sign with the stable self-signed cert
# so TCC grants (FDA later) survive rebuilds. See macos-native-tool skill, Recipe 1+2.
set -euo pipefail
cd "$(dirname "$0")/.."

CERT="${SWEEP_CERT:-Nodu Sim Local Signer}"
APP="$HOME/Applications/Sweep.app"

swift build -c release
BIN=".build/release/SweepApp"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sweep"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Sweep</string>
  <key>CFBundleIdentifier</key><string>com.aditya.sweep</string>
  <key>CFBundleName</key><string>Sweep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST

# Bundle the rule catalog read-only (Codex finding #10).
mkdir -p "$APP/Contents/Resources/rules"
cp rules/schema.json "$APP/Contents/Resources/rules/"
[ -f rules/catalog.json ] && cp rules/catalog.json "$APP/Contents/Resources/rules/" || true

codesign --force --sign "$CERT" --timestamp=none "$APP"
codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf" \
  && echo "Signed with stable identity: OK" \
  || { echo "WARNING: designated requirement is not cert-based; TCC grants will not persist"; exit 1; }

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built: $APP"
