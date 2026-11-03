#!/bin/zsh
# Собирает Release-версию Mac Utilities и упаковывает её в DMG-установщик.
# Результат: builds/Mac-Utilities-<версия>.dmg (отслеживается git; старые версии удаляются).
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
APP="$BUILD/DerivedData/Build/Products/Release/Mac Utilities.app"
STAGING="$BUILD/dmg-staging"

# Каждая сборка получает новый номер: последняя цифра версии и номер сборки +1
# (0.4.0 (4) → 0.4.1 (5)). Отключить: NO_BUMP=1 Scripts/make_dmg.sh
PBXPROJ="$ROOT/MacUtilities.xcodeproj/project.pbxproj"
if [[ -z "${NO_BUMP:-}" ]]; then
  CURRENT=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$PBXPROJ" | awk '{print $3}')
  BUILD_NUMBER=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBXPROJ" | awk '{print $3}')
  NEXT=$(echo "$CURRENT" | awk -F. '{printf "%d.%d.%d", $1, $2, $3 + 1}')
  NEXT_BUILD=$((BUILD_NUMBER + 1))
  sed -i '' "s/MARKETING_VERSION = $CURRENT;/MARKETING_VERSION = $NEXT;/g; s/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PBXPROJ"
  echo "Версия: $CURRENT ($BUILD_NUMBER) → $NEXT ($NEXT_BUILD)" >&2
fi

xcodebuild -project "$ROOT/MacUtilities.xcodeproj" -scheme MacUtilities -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" build | grep -E "error|BUILD" || true
[[ -d "$APP" ]] || { echo "Сборка не найдена: $APP" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUTPUT="$ROOT/builds"
mkdir -p "$OUTPUT"
DMG="$OUTPUT/Mac-Utilities-$VERSION.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/Scripts/INSTALL.txt" "$STAGING/Как установить.txt"

hdiutil create -volname "Mac Utilities $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
# Подпись образа тем же сертификатом, что и приложение (если он есть в связке ключей).
codesign --sign "Apple Development" --timestamp=none "$DMG" 2>/dev/null || true
rm -rf "$STAGING"
# В builds/ остаётся только текущая версия.
find "$OUTPUT" -maxdepth 1 -name "*.dmg" ! -name "Mac-Utilities-$VERSION.dmg" -delete
echo "$DMG"
