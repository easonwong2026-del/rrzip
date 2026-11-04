#!/bin/bash
# 下载 7-Zip 命令行引擎（arm64）到 Assets/7zz
set -e
cd "$(dirname "$0")/.."

VERSION="26.05"
ASSET="7z${VERSION//./}-mac.tar.xz"   # 7z2605-mac.tar.xz
PRIMARY="https://github.com/ip7z/7zip/releases/download/${VERSION}/${ASSET}"
MIRROR="https://gh-proxy.com/${PRIMARY}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载 7-Zip ${VERSION}"
if ! curl -fsSL --max-time 180 -o "$TMP/7z.tar.xz" "$PRIMARY"; then
    echo "   直连失败，改用镜像"
    curl -fsSL --max-time 180 -o "$TMP/7z.tar.xz" "$MIRROR"
fi

tar -xJf "$TMP/7z.tar.xz" -C "$TMP"
mkdir -p Assets
cp "$TMP/7zz" Assets/7zz
chmod +x Assets/7zz
xattr -cr Assets/7zz 2>/dev/null || true

echo "==> 完成：Assets/7zz ($(du -h Assets/7zz | cut -f1))"
