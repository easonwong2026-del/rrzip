#!/bin/bash
# rrzip 构建脚本：直接产出一个可双击运行的 .app
set -e
cd "$(dirname "$0")"

APP_NAME="rrzip"
BUNDLE="build/${APP_NAME}.app"
MIN_MACOS="14.0"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>rrzip</string>
    <key>CFBundleDisplayName</key><string>rrzip</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.rrzip.mac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.10.0</string>
    <key>CFBundleVersion</key><string>20</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>用 rrzip 压缩</string></dict>
            <key>NSMessage</key><string>compressWithRrzip</string>
            <key>NSPortName</key><string>rrzip</string>
            <key>NSSendFileTypes</key><array><string>public.item</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>用 rrzip 打开</string></dict>
            <key>NSMessage</key><string>openWithRrzip</string>
            <key>NSPortName</key><string>rrzip</string>
            <key>NSSendFileTypes</key><array><string>public.item</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>用 rrzip 解压到此处</string></dict>
            <key>NSMessage</key><string>extractHereWithRrzip</string>
            <key>NSPortName</key><string>rrzip</string>
            <key>NSSendFileTypes</key><array><string>public.item</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>用 rrzip 分别压缩</string></dict>
            <key>NSMessage</key><string>compressEachWithRrzip</string>
            <key>NSPortName</key><string>rrzip</string>
            <key>NSSendFileTypes</key><array><string>public.item</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.rrzip.entry</string>
            <key>UTTypeDescription</key><string>rrzip archive entry</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>归档文件</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>public.bzip2-archive</string>
                <string>org.tukaani.xz-archive</string>
                <string>org.7-zip.7-zip-archive</string>
                <string>com.rarlab.rar-archive</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> 编译"
DEBUG_FLAGS=""
if [ "${DEBUG:-0}" = "1" ]; then
    DEBUG_FLAGS="-DDEBUG -Onone"
    echo "    (调试构建：包含 --goto / demo 等调试入口)"
fi
xcrun swiftc \
    -O $DEBUG_FLAGS -swift-version 5 -parse-as-library \
    -target arm64-apple-macos${MIN_MACOS} \
    -framework AppKit -framework SwiftUI -framework PDFKit -framework AVFoundation -framework AVKit -framework QuickLookUI -framework UniformTypeIdentifiers \
    -o "$BUNDLE/Contents/MacOS/${APP_NAME}" \
    Sources/*.swift

echo "==> 复制 7-Zip 引擎"
if [ ! -x Assets/7zz ]; then
    ./scripts/fetch-7zz.sh
fi
cp Assets/7zz "$BUNDLE/Contents/Resources/7zz"
chmod +x "$BUNDLE/Contents/Resources/7zz"
xattr -cr "$BUNDLE/Contents/Resources/7zz" 2>/dev/null || true

if [ -f Assets/AppIcon.icns ]; then
    echo "==> 复制图标"
    cp Assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# 设置里的「查看版本说明」直接读包内这份，不联网
if [ -f RELEASE_NOTES.md ]; then
    cp RELEASE_NOTES.md "$BUNDLE/Contents/Resources/RELEASE_NOTES.md"
fi

echo "==> 构建快速查看扩展"
APEXPATH="$BUNDLE/Contents/PlugIns/ArchivePreview.appex"
mkdir -p "$APEXPATH/Contents/MacOS"
cat > "$APEXPATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ArchivePreview</string>
    <key>CFBundleExecutable</key><string>ArchivePreview</string>
    <key>CFBundleIdentifier</key><string>com.rrzip.mac.preview</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>2.10.0</string>
    <key>CFBundleVersion</key><string>20</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.quicklook.preview</string>
        <key>NSExtensionPrincipalClass</key><string>PreviewProvider</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLSupportedContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>public.bzip2-archive</string>
                <string>org.tukaani.xz-archive</string>
                <string>org.7-zip.7-zip-archive</string>
                <string>com.rarlab.rar-archive</string>
            </array>
            <key>QLIsDataBasedPreview</key><false/>
        </dict>
    </dict>
</dict>
</plist>
PLIST

cat > /tmp/rrzip-appex.entitlements <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
PLIST

xcrun swiftc \
    -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macos${MIN_MACOS} \
    -module-name ArchivePreview \
    -framework AppKit -framework QuickLookUI \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APEXPATH/Contents/MacOS/ArchivePreview" \
    Sources/Archive.swift Sources/FormatCatalog.swift Sources/FormatDetector.swift Sources/ArchiveService.swift QuickLook/PreviewProvider.swift

codesign --force --sign - --entitlements /tmp/rrzip-appex.entitlements "$APEXPATH" >/dev/null 2>&1

echo "==> 构建访达扩展"
FSXPATH="$BUNDLE/Contents/PlugIns/ArchiveFinder.appex"
mkdir -p "$FSXPATH/Contents/MacOS"
FSXV=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUNDLE/Contents/Info.plist")
FSXB=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUNDLE/Contents/Info.plist")
cat > "$FSXPATH/Contents/Info.plist" <<FPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ArchiveFinder</string>
    <key>CFBundleIdentifier</key><string>com.rrzip.mac.finder</string>
    <key>CFBundleName</key><string>ArchiveFinder</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>${FSXV}</string>
    <key>CFBundleVersion</key><string>${FSXB}</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
        <key>NSExtensionPrincipalClass</key><string>ArchiveFinder.FinderSync</string>
    </dict>
</dict>
</plist>
FPLIST

xcrun swiftc \
    -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macos${MIN_MACOS} \
    -module-name ArchiveFinder \
    -framework Cocoa -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$FSXPATH/Contents/MacOS/ArchiveFinder" \
    Sources/Archive.swift Sources/FormatCatalog.swift Sources/FormatDetector.swift \
    Sources/ArchiveService.swift FinderSync/MenuBuilder.swift FinderSync/FinderSync.swift
codesign --force --sign - "$FSXPATH" >/dev/null 2>&1

echo "==> 签名（ad-hoc）"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1  # 不用 --deep，避免覆盖扩展的 entitlements

echo "==> 完成：$BUNDLE"
du -sh "$BUNDLE"
