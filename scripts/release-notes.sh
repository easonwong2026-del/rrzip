#!/bin/bash
# 从 RELEASE_NOTES.md 里取某个版本的段落，给 gh release create --notes-file 用。
#
# 以前 release.yml 直接 --notes-file RELEASE_NOTES.md，把 2.12.0 到 2.0.0 的
# 全部历史都贴到 Release 正文里（9000 字）。发版页面只该有这一版。
set -e
cd "$(dirname "$0")/.."

VERSION=${1:?用法: scripts/release-notes.sh v2.12.0 [文件]}
FILE=${2:-RELEASE_NOTES.md}
KEY=${VERSION#v}

if [ ! -f "$FILE" ]; then
    echo "找不到 $FILE" >&2
    exit 1
fi

NOTES=$(awk -v key="$KEY" '
    # 版本标题形如 "### 2.12.0 视觉重做与任务反馈"
    $0 ~ "^### " key "([^0-9.]|$)" {
        sub(/^### /, "## ")
        print
        found = 1
        next
    }
    found && /^### / { exit }
    found { print }
' "$FILE")

if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
    echo "$FILE 里找不到 $KEY 的段落" >&2
    exit 1
fi

printf '%s\n' "$NOTES"
