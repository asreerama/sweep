#!/bin/bash
# Sweep CI: build workspace + run every package's tests. Any failure fails the run.
# Usage: scripts/ci.sh [--skip-app]
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== swift build (workspace root) =="
if [ "${1:-}" != "--skip-app" ]; then
  swift build 2>&1 | tail -5
fi

echo "== swift test: root (SweepAppTests) =="
swift test 2>&1 | tail -3

for pkg in Packages/*/; do
  echo "== swift test: $pkg =="
  swift test --package-path "$pkg" 2>&1 | tail -8
done
echo "CI PASS"
