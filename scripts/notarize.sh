#!/bin/bash
# 用 Developer ID 重签并公证。需要 Apple Developer Program 账号。
#
# 用法：
#   export IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   ./scripts/notarize.sh
#
# 一次性准备（凭据存 keychain，不进仓库）：
#   xcrun notarytool store-credentials rrzip \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# ⚠️ 前置：先跑 ./scripts/poc-sandbox.sh
#    公证要求扩展启用 App Sandbox，而沙盒下能不能执行包内 7zz 至今没验证过
#    （ad-hoc 签名开不了沙盒，脚本会以 exit 133 直接退出）。
#    如果 POC 结论是「沙盒里跑不了 7zz」，执行层必须先改成「扩展发命令、主 app 执行」，
#    否则公证出来的包，右键菜单点下去只会失败。
#    本脚本不替 build.sh 加沙盒 entitlement——那是产品决策，不是打包步骤。

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=$(pwd)
APP="$ROOT/build/rrzip.app"
PROFILE="${NOTARY_PROFILE:-rrzip}"
ZIP="$ROOT/build/rrzip-notarize.zip"

if [ -z "${IDENTITY:-}" ]; then
    echo "缺少 IDENTITY。示例："
    echo '  export IDENTITY="Developer ID Application: Your Name (TEAMID)"'
    exit 1
fi

if [ ! -d "$APP" ]; then
    echo "找不到 $APP，先跑 ./build.sh"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "==> 签名 $VERSION（$IDENTITY）"

# 先签扩展再签主 app，不加 --deep：--deep 会覆盖扩展自己的 entitlements
for appex in "$APP"/Contents/PlugIns/*.appex; do
    [ -d "$appex" ] || continue
    echo "    $(basename "$appex")"
    codesign --force --timestamp --options runtime \
        --sign "$IDENTITY" "$appex"
done

codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 打包"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 提交公证（首次通常 1–5 分钟）"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> 装订票据"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper 终检"
if spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID"; then
    echo "    ✅ accepted / Notarized Developer ID"
else
    echo "    ❌ 未通过，看上面的 spctl 输出"
    exit 1
fi

echo "==> 完成：$APP"
echo "    分发时打包 build/rrzip-$VERSION.zip（ditto 保留权限与签名）"
