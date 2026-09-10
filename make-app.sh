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

# Иконка приложения
if [ -f "Resources/AppIcon.icns" ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSFaceIDUsageDescription</key>
    <string>Touch ID разблокирует хранилище сессий</string>
</dict>
</plist>
PLIST

# Старый процесс редактора переживает пересборку и маскирует новые правки —
# прибиваем, чтобы следующий запуск гарантированно был свежим бинарём.
killall QTermEditor 2>/dev/null || true

# --- вложенное приложение-редактор (своя иконка в доке)
EDITOR_NAME="QTermEditor"
EDITOR_BIN=".build/$BUILD_CONFIG/$EDITOR_NAME"
if [ -f "$EDITOR_BIN" ]; then
  EDITOR_APP="$APP/Contents/Library/$EDITOR_NAME.app"
  mkdir -p "$EDITOR_APP/Contents/MacOS" "$EDITOR_APP/Contents/Resources"
  cp "$EDITOR_BIN" "$EDITOR_APP/Contents/MacOS/$EDITOR_NAME"
  # У редактора СВОЯ иконка (визуально отличается в доке от QTerm).
  if [ -f "Resources/EditorIcon.icns" ]; then
    cp Resources/EditorIcon.icns "$EDITOR_APP/Contents/Resources/AppIcon.icns"
  elif [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$EDITOR_APP/Contents/Resources/AppIcon.icns"
  fi
  cat > "$EDITOR_APP/Contents/Info.plist" <<EPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$EDITOR_NAME</string>
    <key>CFBundleIdentifier</key><string>com.q00000p.qterm.editor</string>
    <key>CFBundleName</key><string>QTerm Editor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUM</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EPLIST
  codesign --force --deep -s "$SIGN_IDENTITY" "$EDITOR_APP" >/dev/null 2>&1 || true
  echo "==> вложен $EDITOR_NAME.app"
fi

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
