#!/bin/bash
# Installs Good Morning.app into /Applications (or ~/Applications if not writable).
set -e
URL="https://github.com/tejua/GoodMorningApp/releases/latest/download/GoodMorningApp-macOS.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Good Morning..."
curl -fsSL "$URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x GoodMorning 2>/dev/null || true
rm -rf "$DEST/Good Morning.app"
mv "$TMP/Good Morning.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Good Morning.app" 2>/dev/null || true
echo "Installed to $DEST/Good Morning.app"
open "$DEST/Good Morning.app"
