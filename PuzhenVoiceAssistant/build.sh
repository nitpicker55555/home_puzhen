#!/bin/bash
# Builds PuzhenAssistant.app (a menu-bar macOS app) from Sources/main.swift.
set -euo pipefail
cd "$(dirname "$0")"

APP="PuzhenAssistant"
BUNDLE="build/$APP.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
RES_DIR="$BUNDLE/Contents/Resources"

echo "▶︎ Cleaning…"
rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "▶︎ Compiling (this is native Swift, ~10s)…"
swiftc -O \
    -framework AppKit -framework AVFoundation -framework Speech \
    -o "$MACOS_DIR/$APP" \
    Sources/main.swift

cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "▶︎ Signing (ad-hoc, so macOS remembers the mic permission)…"
codesign --force --sign - "$BUNDLE"

echo ""
echo "✅ Built:  $BUNDLE"
echo ""
echo "1) Set your key:   cp .env.example .env   then edit .env"
echo "2) First run:      ./run.sh              (loads .env, shows logs + permission prompts)"
