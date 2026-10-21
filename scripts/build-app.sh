#!/bin/zsh
# Compila e empacota CleanerCRTV.app em ./build.
# Uso: scripts/build-app.sh [--install]
#   --install  copia para /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${APP:-build/CleanerCRTV.app}
VERSION=1.0.0
BUILD_NUMBER=1
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
  esac
done

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CleanerCRTV "$APP/Contents/MacOS/CleanerCRTV"
strip -S "$APP/Contents/MacOS/CleanerCRTV"  # tira caminhos de debug do binário

# Ícone Liquid Glass do Icon Composer
if xcrun --find actool >/dev/null 2>&1 && [[ -d Resources/AppIcon.icon ]]; then
  rm -rf build/actool && mkdir -p build/actool
  xcrun actool Resources/AppIcon.icon \
    --compile build/actool \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist build/actool/partial.plist \
    --errors --warnings --output-format human-readable-text >/dev/null
  cp build/actool/Assets.car "$APP/Contents/Resources/"
  cp build/actool/AppIcon.icns "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CleanerCRTV</string>
  <key>CFBundleDisplayName</key><string>CleanerCRTV</string>
  <key>CFBundleIdentifier</key><string>com.lipenoe.cleanercrtv</string>
  <key>CFBundleExecutable</key><string>CleanerCRTV</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>O CleanerCRTV usa AppleScript para pedir a senha de administrador em tarefas de manutenção que você mandar rodar.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "OK: $APP ($(du -sh "$APP" | cut -f1))"

if [[ $INSTALL == 1 ]]; then
  rm -rf /Applications/CleanerCRTV.app
  ditto "$APP" /Applications/CleanerCRTV.app
  echo "Instalado em /Applications/CleanerCRTV.app"
fi
