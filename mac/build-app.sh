#!/bin/zsh
# Builds mac/NoteDeck.app (menubar app) and mac/.build/release/notedeck-cli
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -vE "^\s*$" | tail -20
APP=NoteDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NoteDeck "$APP/Contents/MacOS/NoteDeck"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/icons" && cp icons/*.svg "$APP/Contents/Resources/icons/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"
echo "cli:   $(pwd)/.build/release/notedeck-cli"
