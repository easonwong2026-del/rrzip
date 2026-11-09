#!/bin/bash
# 退出流程的本机冒烟测试（需要图形登录会话，CI 不跑这个）。
#
# 单元测试覆盖的是状态机与队列语义；这里验的是真进程：
#   1. 没有任务：直接退出
#   2. 正在压缩：选择「等待完成后退出」，压缩跑完、产物完整、随后退出
#   3. 正在压缩：选择「取消任务并退出」，快速退出、不留下半成品
#
# 用法：./scripts/smoke-exit.sh
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP="build/rrzip.app"
BIN="$APP/Contents/MacOS/rrzip"
DOMAIN="com.rrzip.mac"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rrzip-smoke.XXXXXX")
PASS=0
FAIL=0

cleanup() {
    killall rrzip >/dev/null 2>&1 || true
    defaults delete "$DOMAIN" rrzip.smokeQuitAfter >/dev/null 2>&1 || true
    defaults delete "$DOMAIN" rrzip.smokeCompress >/dev/null 2>&1 || true
    defaults delete "$DOMAIN" rrzip.smokeTerminationChoice >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

# 启动 app，等它自己退出；超时就判失败。$1 = 超时秒数
wait_exit() {
    local limit=$1 pid=$2 waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$limit" ]; then
            kill -9 "$pid" 2>/dev/null || true
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

echo "==> 调试构建（冒烟开关只在 DEBUG 里）"
DEBUG=1 ./build.sh > "$WORK/build.log" 2>&1 || { echo "构建失败，见 $WORK/build.log"; exit 1; }

# ---------------------------------------------------------------- 1. 没有任务
echo "==> 场景 1：没有任务，直接退出"
defaults write "$DOMAIN" rrzip.smokeQuitAfter -float 2
defaults delete "$DOMAIN" rrzip.smokeCompress >/dev/null 2>&1 || true
"$BIN" > "$WORK/case1.log" 2>&1 &
PID=$!
if wait_exit 20 "$PID"; then ok "队列为空时直接退出（不再弹确认框）"
else bad "没有任务却没能退出"; fi

# ------------------------------------------------------- 2. 正在压缩：等待完成
echo "==> 场景 2：正在压缩，选择「等待完成后退出」"
SRC="$WORK/wait-src"
mkdir -p "$SRC"
dd if=/dev/urandom of="$SRC/big.bin" bs=1m count=200 2>/dev/null
defaults write "$DOMAIN" rrzip.smokeCompress "$SRC"
defaults write "$DOMAIN" rrzip.smokeQuitAfter -float 2
defaults write "$DOMAIN" rrzip.smokeTerminationChoice wait
"$BIN" > "$WORK/case2.log" 2>&1 &
PID=$!
if wait_exit 180 "$PID"; then ok "等到压缩结束才退出"
else bad "等待完成后退出超时"; fi
if [ -f "$SRC.zip" ] && unzip -t "$SRC.zip" >/dev/null 2>&1; then
    ok "压缩产物完整落盘"
else
    bad "压缩产物缺失或损坏"
fi
if ls "$WORK"/.wait-src-* >/dev/null 2>&1; then bad "留下了未清理的临时文件"
else ok "临时文件已清理"; fi

# ------------------------------------------------------- 3. 正在压缩：取消退出
echo "==> 场景 3：正在压缩，选择「取消任务并退出」"
SRC2="$WORK/cancel-src"
mkdir -p "$SRC2"
dd if=/dev/urandom of="$SRC2/big.bin" bs=1m count=400 2>/dev/null
defaults write "$DOMAIN" rrzip.smokeCompress "$SRC2"
defaults write "$DOMAIN" rrzip.smokeTerminationChoice cancel
"$BIN" > "$WORK/case3.log" 2>&1 &
PID=$!
if wait_exit 45 "$PID"; then ok "取消后能及时退出（没有卡在收尾）"
else bad "取消任务后退出超时"; fi
if [ -f "$SRC2.zip" ]; then bad "取消后不该留下产物"
else ok "取消后没有生成半成品压缩包"; fi
if ls "$WORK"/.cancel-src-* >/dev/null 2>&1; then bad "取消后留下临时文件"
else ok "取消后临时文件已清理"; fi

echo ""
echo "冒烟结果：通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
