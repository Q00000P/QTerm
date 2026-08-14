#!/bin/bash
# Сборка QTerm.app из SPM-пакета. Номер билда автоинкрементится при каждой
# сборке (build/.buildnum) и попадает в CFBundleVersion — в заголовке окна
# видно "QTerm 0.1.0 (N)": какая сборка реально запущена.
set -euo pipefail

APP_NAME="QTerm"
BUNDLE_ID="com.q00000p.qterm"
SIGN_IDENTITY="${QTERM_SIGN_IDENTITY:-QTerm Self-Signed}"
BUILD_CONFIG="release"
APP_VERSION="0.1.0"

cd "$(dirname "$0")"
mkdir -p build

# --- автоинкремент номера билда
BUILDNUM_FILE="build/.buildnum"
BUILD_NUM=$(( $(cat "$BUILDNUM_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$BUILD_NUM" > "$BUILDNUM_FILE"

echo "==> swift build ($BUILD_CONFIG) — билд #$BUILD_NUM"
swift build -c "$BUILD_CONFIG"

BIN=".build/$BUILD_CONFIG/$APP_NAME"
[ -f "$BIN" ] || { echo "Бинарь не найден: $BIN"; exit 1; }

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUM</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSFaceIDUsageDescription</key>
    <string>Touch ID разблокирует хранилище сессий</string>
</dict>
</plist>
PLIST

echo "==> codesign"
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
    echo "Подписано: $SIGN_IDENTITY (билд #$BUILD_NUM)"
else
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! СЕРТ '$SIGN_IDENTITY' НЕ НАЙДЕН — AD-HOC   !!!"
    echo "!!! Keychain-права будут слетать. make-cert.sh !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Готово: $APP (билд #$BUILD_NUM)"
