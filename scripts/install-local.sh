#!/bin/bash
# 本地安装 / 重新注册：让访达与快速查看扩展立刻跑最新构建。
#
# 什么时候要跑：每次改了 FinderSync/ 或 QuickLook/ 下的代码。
# 只 build 不重注册，右键菜单跑的仍是上一次加载进 Finder 的二进制——
# 表现就是「代码明明改了，行为没变」。
#
# 用法：
#   ./scripts/install-local.sh              注册 + 重启访达 + 启动应用
#   ./scripts/install-local.sh --no-finder  不重启访达（自己手动重启）

set -uo pipefail
cd "$(dirname "$0")/.."

APP="$(pwd)/build/rrzip.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ ! -d "$APP" ]; then
    echo "找不到 $APP，先跑 ./build.sh"
    exit 1
fi

echo "==> 1/5 退出正在运行的 rrzip"
if pkill -x rrzip 2>/dev/null; then
    echo "    已退出"
else
    echo "    没有在运行"
fi

echo "==> 2/5 清理指向已删除副本的注册"
# 从临时目录（/private/tmp/...）跑过的版本会在 LaunchServices 里留下记录，
# 右键菜单可能一直指向那个已经不存在的 app。加新路径前先把旧的抹掉。
for stale in /private/tmp/rel201/rrzip.app /tmp/rrzip.app; do
    [ -d "$stale" ] && continue
    if "$LSREGISTER" -u "$stale" 2>/dev/null; then
        echo "    已移除 $stale"
    fi
done
echo "    （还有别的旧路径：$LSREGISTER -dump | grep -i 'rrzip.app'）"

echo "==> 3/5 注册应用"
"$LSREGISTER" -f "$APP" && echo "    $APP"

echo "==> 4/5 注册并启用扩展"
pluginkit -a "$APP/Contents/PlugIns/ArchiveFinder.appex" 2>&1 | sed 's/^/    /'
pluginkit -a "$APP/Contents/PlugIns/ArchivePreview.appex" 2>&1 | sed 's/^/    /'
# -a 只是登记，-e use 才是让它参与匹配
pluginkit -e use -i com.rrzip.mac.finder 2>&1 | sed 's/^/    /'
pluginkit -e use -i com.rrzip.mac.preview 2>&1 | sed 's/^/    /'

echo "==> 5/5 重启访达"
if [ "${1:-}" = "--no-finder" ]; then
    echo "    跳过（手动：killall Finder）"
else
    if killall Finder 2>/dev/null; then
        echo "    访达已重启"
    else
        echo "    访达没在运行或重启失败，手动执行：killall Finder"
    fi
fi

echo ""
echo "==> 注册状态（应能看到 rrzip 的 FinderSync 条目）"
pluginkit -m -i com.rrzip.mac.finder 2>&1 | sed 's/^/    /'
pluginkit -m -i com.rrzip.mac.preview 2>&1 | sed 's/^/    /'

echo ""
echo "==> 启动应用"
open "$APP"

cat <<'NEXT'

下一步（脚本替不了这一步，那是系统权限）：
  1. 系统设置 → 通用 → 登录项与扩展 → 访达扩展，确认 rrzip 已勾选
  2. 右键一个压缩包，应看到「rrzip ▸」，展开有 3 项
  3. 没出现时看扩展日志：
     log stream --predicate 'process == "ArchiveFinder"' --level debug

排查顺序：
  菜单完全没有 → 扩展没被加载（看第 1 步勾选 / 重跑本脚本）
  有菜单但点了解压没反应 → 看通知与 ~/Library/Application Support/rrzip/finder-jobs.log
  菜单项少了 → 设置 → 访达与预览 里被关掉了
NEXT
