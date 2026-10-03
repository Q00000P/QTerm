#!/bin/bash
# Сборка QTerm.app из SPM-пакета. Номер билда автоинкрементится при каждой
# сборке (build/.buildnum) и попадает в CFBundleVersion — в заголовке окна
# видно "QTerm 0.1.0 (N)": какая сборка реально запущена.
set -euo pipefail

APP_NAME="QTerm"
BUNDLE_ID="com.q00000p.qterm"
SIGN_IDENTITY="${QTERM_SIGN_IDENTITY:-QTerm Self-Signed}"
BUILD_CONFIG="release"
APP_VERSION="3.11.4"

cd "$(dirname "$0")"
mkdir -p build

# --- автоинкремент номера билда
BUILDNUM_FILE="build/.buildnum"
BUILD_NUM=$(( $(cat "$BUILDNUM_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$BUILD_NUM" > "$BUILDNUM_FILE"

echo "==> swift build ($BUILD_CONFIG) — билд #$BUILD_NUM"
swift build -c "$BUILD_CONFIG"

# Каталог продуктов сборки (у Xcode 27 / Swift Build он другой — спрашиваем).
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -f "$BIN" ] || { echo "Бинарь не найден: $BIN"; exit 1; }

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Иконка приложения
if [ -f "Resources/AppIcon.icns" ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Ресурсы пакетов (*.bundle: tree-sitter-запросы CodeEditLanguages, шейдеры
# SwiftTerm…). Сборка Swift Build (Xcode 27) ищет их ТОЛЬКО в
# Contents/Resources приложения — без копии редактор падал на первом файле.
# Где лежат бандлы: обычно рядом с бинарём; на всякий случай ищем и в .build.
BUNDLES=()
for b in "$BIN_DIR"/*.bundle; do [ -d "$b" ] && BUNDLES+=("$b"); done
if [ ${#BUNDLES[@]} -eq 0 ]; then
  while IFS= read -r b; do BUNDLES+=("$b"); done < <(find .build -maxdepth 6 -type d -name "*_*.bundle" -path "*elease*" 2>/dev/null)
fi
echo "==> ресурсы пакетов: ${#BUNDLES[@]} шт. ($(for b in ${BUNDLES[@]+"${BUNDLES[@]}"}; do basename "$b"; done | tr '\n' ' '))"
copy_bundles() {
  local dest="$1"
  mkdir -p "$dest"
  for b in ${BUNDLES[@]+"${BUNDLES[@]}"}; do
    rm -rf "$dest/$(basename "$b")"
    cp -R "$b" "$dest/"
  done
}
copy_bundles "$APP/Contents/Resources"

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
    <key>NSLocalNetworkUsageDescription</key>
    <string>QTerm подключается по SSH к серверам и роутерам в локальной сети</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <!-- «Ноды 3x-ui»: панели бывают по http и с самоподписанным сертификатом («Не проверять») -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Старый процесс редактора переживает пересборку и маскирует новые правки —
# прибиваем, чтобы следующий запуск гарантированно был свежим бинарём.
killall QTermEditor 2>/dev/null || true

# --- вложенное приложение-редактор (своя иконка в доке)
EDITOR_NAME="QTermEditor"
EDITOR_BIN="$BIN_DIR/$EDITOR_NAME"
if [ -f "$EDITOR_BIN" ]; then
  EDITOR_APP="$APP/Contents/Library/$EDITOR_NAME.app"
  mkdir -p "$EDITOR_APP/Contents/MacOS" "$EDITOR_APP/Contents/Resources"
  cp "$EDITOR_BIN" "$EDITOR_APP/Contents/MacOS/$EDITOR_NAME"
  copy_bundles "$EDITOR_APP/Contents/Resources"
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
