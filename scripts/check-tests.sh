#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/test.sh 2>&1 | tee /tmp/test.log
# CI 与发版共用完整套件的断言基线（含 7zz）。
minimum=1212
count=$(sed -n 's/^全部通过（\([0-9][0-9]*\) 项）$/\1/p' /tmp/test.log)
case "$count" in
    ''|*[!0-9]*) echo "::error::未找到唯一的测试总数"; exit 1 ;;
esac
if [ "$count" -lt "$minimum" ]; then
    echo "::error::测试数 $count 低于基线 $minimum"
    exit 1
fi
echo "测试通过 $count 项"
