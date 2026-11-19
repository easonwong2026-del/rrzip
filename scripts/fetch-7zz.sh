#!/bin/bash
# 下载 7-Zip 命令行引擎（arm64）到 Assets/7zz，并强制校验 SHA256
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="26.05"
ASSET="7z${VERSION//./}-mac.tar.xz"   # 7z2605-mac.tar.xz
PRIMARY="https://github.com/ip7z/7zip/releases/download/${VERSION}/${ASSET}"
MIRROR="https://gh-proxy.com/${PRIMARY}"

# 固定哈希：升级 VERSION 时必须同步更新，否则校验失败（宁可红，不装来源不明的二进制）。
#   TAR   = 官方 Release 资产 7z2605-mac.tar.xz 的 SHA256
#   BIN   = 解包后 7zz 的 SHA256，与仓库内 Assets/7zz 一致（2026-11-19 核对）
# 需要临时用别的镜像/版本时可用环境变量覆盖。
EXPECTED_SHA256="${SEVENZIP_TAR_SHA256:-12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570}"
EXPECTED_BIN_SHA256="${SEVENZIP_BIN_SHA256:-8e495531e1b2b8cb169ca583493922d4ab386007756418c15b95f07f642c35fb}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载 7-Zip ${VERSION}"
if ! curl -fsSL --max-time 180 -o "$TMP/7z.tar.xz" "$PRIMARY"; then
    if [ "${ALLOW_MIRROR:-0}" = "1" ]; then
        echo "   直连失败，已显式启用 ALLOW_MIRROR=1，改用镜像（仍将强制校验 SHA256）"
        curl -fsSL --max-time 180 -o "$TMP/7z.tar.xz" "$MIRROR"
    else
        echo "错误：直连 GitHub 下载失败。为防止供应链投毒，默认已禁用第三方代理镜像。" >&2
        echo "如确认需要通过镜像下载，请配合固定 SHA256 显式传入 ALLOW_MIRROR=1。" >&2
        exit 1
    fi
fi

echo "==> 校验 SHA256"
printf '%s  %s\n' "$EXPECTED_SHA256" "$TMP/7z.tar.xz" | shasum -a 256 -c -

tar -xJf "$TMP/7z.tar.xz" -C "$TMP"
# 解包后的二进制也要对上：TAR 哈希对但内容被换掉的场景（换包/换解包工具）挡在这里
echo "==> 校验 7zz 可执行文件"
printf '%s  %s\n' "$EXPECTED_BIN_SHA256" "$TMP/7zz" | shasum -a 256 -c -

mkdir -p Assets
cp "$TMP/7zz" Assets/7zz
chmod +x Assets/7zz
xattr -cr Assets/7zz 2>/dev/null || true

echo "==> 完成：Assets/7zz ($(du -h Assets/7zz | cut -f1))"
