#!/bin/bash
# Build "Sweep Menu.app" (local profile): the standalone menubar process (PLAN §3 module 7, the
# P4-B decision-gate split — the in-app menubar measured 92.6 MB idle against a 50 MB budget).
# Modeled on scripts/build-app.sh's bundling + signing steps, without that script's helper-trust-
# hash generation dance: SweepMenu has no privileged helper and no XPC, so there is nothing to
# bake in before compiling. See macos-native-tool skill, Recipe 1+2, for the underlying pattern.
set -euo pipefail
cd "$(dirname "$0")/.."

CERT="${SWEEP_CERT:-Nodu Sim Local Signer}"
APP="$HOME/Applications/Sweep Menu.app"
MAIN_APP="$HOME/Applications/Sweep.app"
BUNDLE_ID="com.aditya.sweep.menu"

# --- 1. Build ---------------------------------------------------------------------------------

swift build -c release --product SweepMenu
BIN=".build/release/SweepMenu"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SweepMenu"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SweepMenu</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Sweep Menu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <!-- No Dock presence, no window — the whole reason this target exists (PLAN §3 module 7). -->
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# --- 2. Sign with the same stable cert as the main app + helper (scripts/build-app.sh) --------
#
# Stable identity here matters for the same reason it does there (macos-native-tool skill,
# Recipe 2): `SMAppService.loginItem(identifier:)`'s registration is keyed to this bundle's
# designated requirement, and TCC/login-item approval must survive rebuilds, not just the first one.

codesign --force --sign "$CERT" --timestamp=none "$APP"

if codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf"; then
  echo "Sweep Menu signed with stable identity: OK"
else
  echo "ERROR: Sweep Menu's designated requirement is not cert-based; login-item approval will not persist"
  exit 1
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built: $APP"

# --- 3. Embed as SMAppService's login item, if the main app is already built ------------------
#
# `SMAppService.loginItem(identifier:)` (Sources/SweepApp/Sentinel/MenuBarLoginItemSettings.swift)
# only finds a login item bundled inside its container app, at `Contents/Library/LoginItems` —
# Apple's documented location, the same rule `scripts/build-app.sh` already follows for
# `Contents/Library/LaunchDaemons`. That folder is populated here, by this script, rather than by
# `build-app.sh` (out of this script's ownership) — the trade is that this step needs re-running
# after every `build-app.sh` rebuild of `Sweep.app` itself, since a fresh build starts from a
# clean bundle with no `LoginItems` folder yet. Signing order matters here too, same inside-out
# rule `build-app.sh` documents: the nested item must already be sealed (step 2 above) before the
# outer bundle is resealed below.
if [ -d "$MAIN_APP" ]; then
  mkdir -p "$MAIN_APP/Contents/Library/LoginItems"
  rm -rf "$MAIN_APP/Contents/Library/LoginItems/Sweep Menu.app"
  cp -R "$APP" "$MAIN_APP/Contents/Library/LoginItems/Sweep Menu.app"
  codesign --force --sign "$CERT" --timestamp=none "$MAIN_APP"
  if codesign -d -r- "$MAIN_APP" 2>&1 | grep -q "certificate leaf"; then
    echo "Embedded Sweep Menu.app into $MAIN_APP/Contents/Library/LoginItems and re-signed: OK"
  else
    echo "ERROR: $MAIN_APP's designated requirement is not cert-based after re-signing"
    exit 1
  fi
else
  echo "NOTE: $MAIN_APP not found — Sweep Menu.app built standalone only, not embedded as a login"
  echo "item yet. Run scripts/build-app.sh first, then this script again, so Settings' menu-bar"
  echo "toggle (SMAppService.loginItem) has something registered to find."
fi
