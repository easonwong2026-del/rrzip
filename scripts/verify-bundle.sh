#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/rrzip.app
test -x "$APP/Contents/MacOS/rrzip"
test -x "$APP/Contents/Resources/7zz"
test -x "$APP/Contents/PlugIns/ArchivePreview.appex/Contents/MacOS/ArchivePreview"
# 访达扩展必须一起验：v2.10.0 只验了快速查看，扩展构建坏了 CI 也不会红
test -d "$APP/Contents/PlugIns/ArchiveFinder.appex"
test -x "$APP/Contents/PlugIns/ArchiveFinder.appex/Contents/MacOS/ArchiveFinder"
plutil -lint "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/PlugIns/ArchivePreview.appex/Contents/Info.plist"
plutil -lint "$APP/Contents/PlugIns/ArchiveFinder.appex/Contents/Info.plist"
# 扩展版本号必须跟着主 app 走
for key in CFBundleShortVersionString CFBundleVersion; do
  mainValue=$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist")
  for extension in ArchivePreview ArchiveFinder; do
    extensionValue=$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/PlugIns/$extension.appex/Contents/Info.plist")
    [ "$mainValue" = "$extensionValue" ] || {
      echo "::error::$extension 的 $key ($extensionValue) 与主 app ($mainValue) 不一致"
      exit 1
    }
  done
done
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"
# dmg 必须是按 app 版本命名的那一份，别拿任意一个 *.dmg 顶数
DMG="build/rrzip-${APP_VERSION}.dmg"
[ -f "$DMG" ] || { echo "::error::没有产出 $DMG"; exit 1; }
hdiutil imageinfo "$DMG" >/dev/null || { echo "::error::$DMG 不是可用的磁盘镜像"; exit 1; }
echo "dmg 就绪：$DMG"
./scripts/release-notes.sh "v${APP_VERSION}" > build/notes.md
echo "发布说明：v${APP_VERSION}"

BIN="$APP/Contents/MacOS/rrzip"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
"$BIN" --help > "$fixture/help.txt"
grep -q -- '--extract' "$fixture/help.txt"
[ "$("$BIN" --version)" = "$APP_VERSION" ]
printf 'rrzip CLI smoke\n' > "$fixture/source.txt"
"$BIN" --create "$fixture/sample.zip" "$fixture/source.txt"
"$BIN" --verify "$fixture/sample.zip"
"$BIN" --extract "$fixture/sample.zip" -o "$fixture/extracted"
cmp "$fixture/source.txt" "$fixture/extracted/source.txt"
echo "CLI 实际产物检查通过：--help --version --create --verify --extract"
