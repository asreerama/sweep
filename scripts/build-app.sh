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
  <!-- AppCleaner-parity drop targets (PLAN §3 module 5): a .app dragged onto Sweep's Dock icon
       while it is closed launches the process, and Launch Services hands the dropped bundle to
       SweepAppDelegate.application(_:open:) as a document-open event. LSHandlerRank "Alternate"
       registers Sweep as *able* to open application bundles without claiming the double-click
       default (that stays Finder/LaunchServices' own "open the app" behavior). -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Application</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>com.apple.application-bundle</string></array>
    </dict>
  </array>
  <!-- sweep://open-uninstall-orphan?bundleID=... — the SmartDelete watcher's own offer-accept
       deep link (TrashOfferPanel), delivered back to the running process via .onOpenURL. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.aditya.sweep.deeplink</string>
      <key>CFBundleURLSchemes</key>
      <array><string>sweep</string></array>
    </dict>
  </array>
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
