#!/bin/bash

# Sweep Fixture Generator
# Generates a deterministic fake junk tree for testing the rule catalog.
# Simulates all major junk categories: caches, logs, developer tools, trash, sparse files.
#
# Usage: ./scripts/make-fixtures.sh [TARGET_DIR]
#   If TARGET_DIR omitted, creates in a temporary directory and prints path at end.
#
# Idempotent: safe to run multiple times on same target.
#
# Structure created:
#   Library/Caches/             User app caches
#   Library/Developer/          Xcode derived data, device support, archives
#   Library/Logs/               Application logs (with varied timestamps)
#   .npm/_cacache/              npm cache
#   .gradle/caches/             Gradle cache
#   .vscode/                    VS Code cache
#   Library/Application Support/Code/  VS Code settings (TRAP: canary file)
#   .Trash/                     Deleted items
#   sparse-*.dat                Large sparse files for size testing

set -euo pipefail

# Determine target directory
if [ -z "${1:-}" ]; then
    TARGET_DIR=$(mktemp -d)
else
    TARGET_DIR="$1"
fi
mkdir -p "$TARGET_DIR"

# Date helpers for realistic timestamps
NOW=$(date +%s)
WEEK_AGO=$((NOW - 7 * 86400))
MONTH_AGO=$((NOW - 30 * 86400))
YEAR_AGO=$((NOW - 365 * 86400))

# Helper to create a file with specific timestamp
# Usage: touch_dated PATH SECONDS_SINCE_EPOCH
touch_dated() {
    local path="$1"
    local timestamp="$2"
    mkdir -p "$(dirname "$path")"
    touch -t "$(date -r "$timestamp" +%Y%m%d%H%M.%S)" "$path"
}

echo "Creating fixture tree at: $TARGET_DIR"

# ============================================================================
# 1. User Application Caches (~/Library/Caches)
# ============================================================================
echo "  Creating Caches directory..."

# Chrome cache
mkdir -p "$TARGET_DIR/Library/Caches/Google/Chrome/Cache"
for i in {1..5}; do
    dd if=/dev/zero of="$TARGET_DIR/Library/Caches/Google/Chrome/Cache/file_$i" bs=1024 count=512 2>/dev/null
done

# Firefox cache
mkdir -p "$TARGET_DIR/Library/Caches/Firefox/Profiles/default/cache2"
for i in {1..4}; do
    dd if=/dev/zero of="$TARGET_DIR/Library/Caches/Firefox/Profiles/default/cache2/file_$i" bs=1024 count=256 2>/dev/null
done

# Safari cache
mkdir -p "$TARGET_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches"
dd if=/dev/zero of="$TARGET_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches/cache.db" bs=1024 count=1024 2>/dev/null

# Generic app caches
for app in "com.google.Chrome" "com.mozilla.firefox" "org.chromium.Chromium"; do
    mkdir -p "$TARGET_DIR/Library/Caches/$app"
    dd if=/dev/zero of="$TARGET_DIR/Library/Caches/$app/cache.db" bs=1024 count=256 2>/dev/null
done

# pip cache
mkdir -p "$TARGET_DIR/Library/Caches/pip/http-v2"
touch_dated "$TARGET_DIR/Library/Caches/pip/http-v2/cached_file.txt" "$MONTH_AGO"

# CocoaPods cache
mkdir -p "$TARGET_DIR/Library/Caches/CocoaPods/Search"
dd if=/dev/zero of="$TARGET_DIR/Library/Caches/CocoaPods/Search/index.db" bs=1024 count=512 2>/dev/null

# Android Studio cache
mkdir -p "$TARGET_DIR/Library/Caches/Google/AndroidStudio2024.1.2/system/caches"
dd if=/dev/zero of="$TARGET_DIR/Library/Caches/Google/AndroidStudio2024.1.2/system/caches/cache.db" bs=1024 count=1024 2>/dev/null

# JetBrains cache
mkdir -p "$TARGET_DIR/Library/Caches/JetBrains/IntelliJIdea2024.1/caches"
for i in {1..3}; do
    touch_dated "$TARGET_DIR/Library/Caches/JetBrains/IntelliJIdea2024.1/caches/file_$i" "$WEEK_AGO"
done

# ============================================================================
# 2. Xcode Caches (~/Library/Developer/Xcode)
# ============================================================================
echo "  Creating Xcode directories..."

# DerivedData with nested build products
mkdir -p "$TARGET_DIR/Library/Developer/Xcode/DerivedData/MyApp-abc123def456/Build/Products/Release"
dd if=/dev/zero of="$TARGET_DIR/Library/Developer/Xcode/DerivedData/MyApp-abc123def456/Build/Products/Release/MyApp.app" bs=1024 count=2048 2>/dev/null
mkdir -p "$TARGET_DIR/Library/Developer/Xcode/DerivedData/MyApp-abc123def456/Index.noindex"
dd if=/dev/zero of="$TARGET_DIR/Library/Developer/Xcode/DerivedData/MyApp-abc123def456/Index.noindex/index.db" bs=1024 count=512 2>/dev/null

# Archives
mkdir -p "$TARGET_DIR/Library/Developer/Xcode/Archives/2024-08-31 10.30.15 +0000.xcarchive"
dd if=/dev/zero of="$TARGET_DIR/Library/Developer/Xcode/Archives/2024-08-31 10.30.15 +0000.xcarchive/archive.db" bs=1024 count=1024 2>/dev/null

# Device Support (iOS DeviceSupport)
for version in "18.0" "17.5" "16.7"; do
    mkdir -p "$TARGET_DIR/Library/Developer/Xcode/iOS DeviceSupport/$version (arm64e)"
    mkdir -p "$TARGET_DIR/Library/Developer/Xcode/iOS DeviceSupport/$version (arm64e)/DeveloperDiskImage"
    dd if=/dev/zero of="$TARGET_DIR/Library/Developer/Xcode/iOS DeviceSupport/$version (arm64e)/DeveloperDiskImage/DeveloperDiskImage.dmg" bs=1024 count=2048 2>/dev/null
done

# tvOS DeviceSupport
mkdir -p "$TARGET_DIR/Library/Developer/Xcode/tvOS DeviceSupport/18.0"
dd if=/dev/zero of="$TARGET_DIR/Library/Developer/Xcode/tvOS DeviceSupport/18.0/info.txt" bs=1024 count=256 2>/dev/null

# CoreSimulator devices
mkdir -p "$TARGET_DIR/Library/Developer/CoreSimulator/Devices/AAAABBBB-CCCC-DDDD-EEEE-FFFFGGGGHHH/data"
dd if=/dev/zero of="$TARGET_DIR/Library/Developer/CoreSimulator/Devices/AAAABBBB-CCCC-DDDD-EEEE-FFFFGGGGHHH/data/device.plist" bs=1024 count=512 2>/dev/null

# ============================================================================
# 3. Logs (~/Library/Logs and system logs)
# ============================================================================
echo "  Creating Logs directories..."

# Crash reports with varied timestamps
mkdir -p "$TARGET_DIR/Library/Logs/DiagnosticReports"
touch_dated "$TARGET_DIR/Library/Logs/DiagnosticReports/old_crash_2023-01-15.crash" "$YEAR_AGO"
touch_dated "$TARGET_DIR/Library/Logs/DiagnosticReports/recent_crash_2024-08-28.crash" "$WEEK_AGO"
touch_dated "$TARGET_DIR/Library/Logs/DiagnosticReports/new_crash_today.crash" "$NOW"

# Application logs
mkdir -p "$TARGET_DIR/Library/Logs/MyApplication"
for i in {1..5}; do
    touch_dated "$TARGET_DIR/Library/Logs/MyApplication/log_$i.log" "$((NOW - i * 86400))"
done

# JetBrains logs
mkdir -p "$TARGET_DIR/Library/Logs/JetBrains/IntelliJIdea2024.1"
for i in {1..3}; do
    touch_dated "$TARGET_DIR/Library/Logs/JetBrains/IntelliJIdea2024.1/idea.log.$i" "$((NOW - i * 86400))"
done

# ============================================================================
# 4. Developer Tool Caches
# ============================================================================
echo "  Creating developer tool caches..."

# npm cache
mkdir -p "$TARGET_DIR/.npm/_cacache"
for i in {1..3}; do
    dd if=/dev/zero of="$TARGET_DIR/.npm/_cacache/cache_entry_$i" bs=1024 count=256 2>/dev/null
done

# Gradle cache
mkdir -p "$TARGET_DIR/.gradle/caches/gradle-7.6/dependency-cache"
dd if=/dev/zero of="$TARGET_DIR/.gradle/caches/gradle-7.6/dependency-cache/cache.db" bs=1024 count=1024 2>/dev/null
mkdir -p "$TARGET_DIR/.gradle/wrapper"
dd if=/dev/zero of="$TARGET_DIR/.gradle/wrapper/gradle-wrapper.jar" bs=1024 count=512 2>/dev/null

# Composer cache
mkdir -p "$TARGET_DIR/.composer/cache/repo"
for i in {1..2}; do
    dd if=/dev/zero of="$TARGET_DIR/.composer/cache/repo/package_$i.json" bs=1024 count=128 2>/dev/null
done

# Pub cache
mkdir -p "$TARGET_DIR/.pub-cache/hosted/pub.dartlang.org"
dd if=/dev/zero of="$TARGET_DIR/.pub-cache/hosted/pub.dartlang.org/package-1.0.0.tar.gz" bs=1024 count=256 2>/dev/null

# Swift PM cache
mkdir -p "$TARGET_DIR/.swiftpm/cache"
dd if=/dev/zero of="$TARGET_DIR/.swiftpm/cache/package_info.json" bs=1024 count=128 2>/dev/null

# Deno cache
mkdir -p "$TARGET_DIR/Library/Caches/deno/deps"
dd if=/dev/zero of="$TARGET_DIR/Library/Caches/deno/deps/package_xyz.ts" bs=1024 count=256 2>/dev/null

# Yarn cache
mkdir -p "$TARGET_DIR/.cache/yarn/v6"
for i in {1..3}; do
    dd if=/dev/zero of="$TARGET_DIR/.cache/yarn/v6/package_$i" bs=1024 count=256 2>/dev/null
done

# ============================================================================
# 5. Editor Caches (VS Code, Cursor)
# ============================================================================
echo "  Creating editor caches..."

# VS Code cache (NOT User dir - that's a trap)
mkdir -p "$TARGET_DIR/Library/Application Support/Code/Cache"
dd if=/dev/zero of="$TARGET_DIR/Library/Application Support/Code/Cache/cache.db" bs=1024 count=512 2>/dev/null

mkdir -p "$TARGET_DIR/Library/Application Support/Code/GPUCache"
dd if=/dev/zero of="$TARGET_DIR/Library/Application Support/Code/GPUCache/index" bs=1024 count=256 2>/dev/null

mkdir -p "$TARGET_DIR/Library/Application Support/Code/CachedData"
dd if=/dev/zero of="$TARGET_DIR/Library/Application Support/Code/CachedData/cache_v1.db" bs=1024 count=512 2>/dev/null

# VS Code User dir (TRAP: must never delete - contains settings)
mkdir -p "$TARGET_DIR/Library/Application Support/Code/User"
cat > "$TARGET_DIR/Library/Application Support/Code/User/FIXTURE_CANARY_DO_NOT_DELETE.txt" << 'EOF'
FIXTURE CANARY: This file marks a critical user data directory.
If this file is deleted during testing, the fixture cleanup was incorrect.
VS Code User directory contains essential settings and should never be cleaned.
EOF

# VS Code extensions (also precious)
mkdir -p "$TARGET_DIR/.vscode/extensions"
mkdir -p "$TARGET_DIR/.vscode/extensions/ms-vscode.cpptools-1.18.5"
touch "$TARGET_DIR/.vscode/extensions/ms-vscode.cpptools-1.18.5/package.json"

# Cursor cache (similar to VS Code)
mkdir -p "$TARGET_DIR/Library/Application Support/Cursor/Cache"
dd if=/dev/zero of="$TARGET_DIR/Library/Application Support/Cursor/Cache/cache.db" bs=1024 count=512 2>/dev/null

# Cursor User dir (TRAP: contains settings, must preserve)
mkdir -p "$TARGET_DIR/Library/Application Support/Cursor/User"
cat > "$TARGET_DIR/Library/Application Support/Cursor/User/FIXTURE_CANARY_DO_NOT_DELETE.txt" << 'EOF'
FIXTURE CANARY: This file marks a critical user data directory.
If this file is deleted during testing, the fixture cleanup was incorrect.
Cursor User directory contains essential settings and should never be cleaned.
EOF

# Zed cache
mkdir -p "$TARGET_DIR/Library/Caches/Zed"
dd if=/dev/zero of="$TARGET_DIR/Library/Caches/Zed/cache.db" bs=1024 count=512 2>/dev/null

# ============================================================================
# 6. Trash
# ============================================================================
echo "  Creating Trash..."

mkdir -p "$TARGET_DIR/.Trash"
for i in {1..5}; do
    dd if=/dev/zero of="$TARGET_DIR/.Trash/DeletedFile_$i.txt" bs=1024 count=128 2>/dev/null
done

# Simulate trash on volume with uid
mkdir -p "$TARGET_DIR/.Trashes/501"
dd if=/dev/zero of="$TARGET_DIR/.Trashes/501/DeletedLargeFile" bs=1024 count=1024 2>/dev/null

# ============================================================================
# 7. Sparse files for size testing
# ============================================================================
echo "  Creating sparse test files..."

# Create sparse files using dd seek (platform-agnostic, no mkfile)
# 1 GB sparse file (allocated blocks vary by filesystem, useful for testing)
dd if=/dev/zero of="$TARGET_DIR/sparse-1gb.dat" bs=1m count=1 seek=1023 2>/dev/null
truncate -s 1g "$TARGET_DIR/sparse-1gb.dat" 2>/dev/null || true

# 500 MB sparse file
dd if=/dev/zero of="$TARGET_DIR/sparse-500mb.dat" bs=1m count=1 seek=499 2>/dev/null
truncate -s 500m "$TARGET_DIR/sparse-500mb.dat" 2>/dev/null || true

# 100 MB regular file (fully allocated)
dd if=/dev/zero of="$TARGET_DIR/regular-100mb.dat" bs=1m count=100 2>/dev/null

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "✓ Fixture tree created successfully"
echo ""
echo "Fixture summary:"
echo "  Base directory: $TARGET_DIR"
echo ""
echo "Included content (rules validation):"
echo "  - ~/Library/Caches/* (various app caches)"
echo "  - ~/Library/Developer/Xcode/* (DerivedData, Archives, DeviceSupport)"
echo "  - ~/Library/Logs/* (app and crash logs with varied timestamps)"
echo "  - ~/.npm/_cacache (npm package cache)"
echo "  - ~/.gradle/caches (Gradle build cache)"
echo "  - ~/.vscode, .composer, .pub-cache, .swiftpm, etc. (dev tool caches)"
echo "  - ~/.Trash and .Trashes (trash directories)"
echo "  - sparse-*.dat (test files for size verification)"
echo ""
echo "CANARY TRAPS (should be skipped by correct rules):"
echo "  - $TARGET_DIR/Library/Application Support/Code/User/FIXTURE_CANARY_DO_NOT_DELETE.txt"
echo "  - $TARGET_DIR/Library/Application Support/Cursor/User/FIXTURE_CANARY_DO_NOT_DELETE.txt"
echo ""
echo "Test use cases:"
echo "  1. Verify size calculation: du -sh $TARGET_DIR/Library/Caches"
echo "  2. Test age filtering: find $TARGET_DIR/Library/Logs -type f -mtime +7"
echo "  3. Verify canary preservation: ls $TARGET_DIR/Library/Application\ Support/Code/User/"
echo "  4. Test trash cleanup: rm -rf $TARGET_DIR/.Trash"
echo ""

# Print the target directory (useful when using default mktemp)
echo "$TARGET_DIR"
