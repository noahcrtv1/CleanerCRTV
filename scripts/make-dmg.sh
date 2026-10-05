#!/bin/zsh
# Gera build/CleanerCRTV-<versão>.dmg com o app, atalho para Aplicativos e LEIA-ME.
# Uso: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export APP=build/full/CleanerCRTV.app
mkdir -p build/full
scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=build/dmg
DMG=build/CleanerCRTV-${VERSION}.dmg

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CleanerCRTV.app"
ln -s /Applications "$STAGE/Aplicativos"
cp scripts/LEIA-ME.txt "$STAGE/LEIA-ME.txt"

hdiutil create -volname "CleanerCRTV" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign - "$DMG"
echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
