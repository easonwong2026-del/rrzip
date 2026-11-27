#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 面板和进度卡即使从未被调用，也会通过 Swift 编译。
for v in CreateArchiveSheet BatchSheet TaskCard; do
  n=$(awk -v name="$v(" '!/^[[:space:]]*\/\// && index($0, name) { n++ } END { print n+0 }' Sources/*.swift)
  if [ "$n" -lt 1 ]; then
    echo "::error::$v 定义了但没有调用点，功能是断的"
    exit 1
  fi
  echo "$v 调用点 $n"
done

source scripts/sources.sh
flags=(-typecheck -swift-version 5 -strict-concurrency=complete -warnings-as-errors
       -target arm64-apple-macos14.0)
check() {
    echo "==> $1"
    shift
    xcrun swiftc "${flags[@]}" "$@"
}
check rrzip Sources/*.swift
check ArchivePreview -DARCHIVE_EXTENSION "${ARCHIVE_CORE[@]}" "${QUICKLOOK_CORE[@]}"
check ArchiveFinder -DARCHIVE_EXTENSION "${ARCHIVE_CORE[@]}" "${SHARED_STATE[@]}" "${FINDER_CORE[@]}" FinderSync/FinderSync.swift
