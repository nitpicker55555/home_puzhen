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
# -sectcreate embeds Info.plist INTO the binary (__TEXT,__info_plist) so macOS
# reads the mic / speech usage strings even when the executable is run directly.
# Without this, TCC kills the process with SIGABRT on first mic/speech access.
swiftc -O \
    -framework AppKit -framework AVFoundation -framework Speech \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist \
    -o "$MACOS_DIR/$APP" \
    Sources/main.swift

cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "▶︎ Signing…"
# A STABLE self-signed identity keeps the same designated requirement across
# rebuilds, so macOS TCC remembers the mic/speech grant (ad-hoc changes the
# cdhash every build and re-prompts). Set up once via setup-signing.sh.
SIGN_KC="$HOME/Library/Keychains/puzhen-signing.keychain-db"
SIGN_ID="Puzhen Assistant Dev"
if security find-identity "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    security unlock-keychain -p puzhen "$SIGN_KC" 2>/dev/null || true
    codesign --force --sign "$SIGN_ID" --keychain "$SIGN_KC" "$BUNDLE"
    echo "  signed with stable identity ✓"
else
    codesign --force --sign - "$BUNDLE"
    echo "  ⚠️ stable identity not found — signed ad-hoc (permissions will reset each build)"
fi

echo ""
echo "✅ Built:  $BUNDLE"
echo ""
echo "1) Set your key:   cp .env.example .env   then edit .env"
echo "2) First run:      ./run.sh              (loads .env, shows logs + permission prompts)"
