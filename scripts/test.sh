#!/bin/bash
# 生成样例归档 → 编译测试 → 运行
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

SRC="$FIX/src"
mkdir -p "$SRC/照片/城市"
printf 'hello\n' > "$SRC/说明.txt"
printf 'space\n' > "$SRC/带 空格.txt"
printf 'x\n' > "$SRC/readme.txt"
head -c 200000 /dev/urandom > "$SRC/照片/城市/001.jpg"
head -c 80000 /dev/urandom > "$SRC/照片/002.jpg"

(cd "$SRC" && /usr/bin/tar -a -cf "$FIX/basic.zip" 说明.txt "带 空格.txt" 照片)
(cd "$SRC" && /usr/bin/tar -czf "$FIX/bundle.tgz" readme.txt)

if [ -x "$ROOT/Assets/7zz" ]; then
    (cd "$SRC" && "$ROOT/Assets/7zz" a -t7z -y -ppw123 -mhe=on "$FIX/secret.7z" 说明.txt >/dev/null)
fi

echo "==> 编译测试"
mkdir -p build
xcrun swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -o build/rrzip-tests \
    Sources/Archive.swift Sources/Model.swift Tests/main.swift

if [ -x "$ROOT/Assets/7zz" ]; then cp "$ROOT/Assets/7zz" build/7zz; fi

echo "==> 运行"
./build/rrzip-tests "$FIX"
