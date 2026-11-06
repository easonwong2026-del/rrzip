#!/bin/bash
# POC：沙盒化的扩展（appex）还能不能执行包内自带的 7zz？
#
# 这是 v2.11.0 最大的未知：模块 E 要公证，公证要求扩展启用 App Sandbox；
# 而现在的执行层是「扩展直接 spawn Contents/Resources/7zz」。
# 两者能不能共存，决定了整个执行层要不要改成「扩展发命令、主 app 执行」。
#
# 做法：造一个最小 app bundle，真的开沙盒，真的去跑 7zz，看三种组合的结果。
#   1) 沙盒 app + 原始 7zz
#   2) 沙盒 app + 用 inherit entitlement 签过的 7zz
#   3) 非沙盒 app + 原始 7zz（基线，确认测试本身没问题）
#
# 退出码：0 = 至少「沙盒 + inherit」能跑（执行层不用重写）
#         1 = 全部沙盒组合都失败（执行层必须改成 XPC 回主 app）

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
POC=$(mktemp -d)
trap 'rm -rf "$POC"' EXIT

# 默认 ad-hoc。**ad-hoc 签名开不了沙盒**：进程会以 exit 133(SIGTRAP) 直接起不来，
# 所以「沙盒 + 7zz」这组必须用真实的 Developer ID 才能验：
#   IDENTITY="Developer ID Application: Xxx (TEAMID)" ./scripts/poc-sandbox.sh
IDENTITY="${IDENTITY:--}"
IS_ADHOC=0
[ "$IDENTITY" = "-" ] && IS_ADHOC=1

SEVENZIP="$ROOT/Assets/7zz"
if [ ! -x "$SEVENZIP" ]; then
    echo "缺少 Assets/7zz，先跑 ./scripts/fetch-7zz.sh"
    exit 2
fi

cat > "$POC/poc.swift" <<'SWIFT'
import Foundation

// 沙盒里只有容器可写，所以结果一律走 stdout（fd 是从父进程继承的）
let bundle = Bundle.main.bundleURL
let tool = bundle.appendingPathComponent("Contents/Resources/7zz")

// 诊断用：只证明自己活着，不做任何 spawn。
// 如果连这一步都起不来，说明 ad-hoc 签名根本开不了沙盒，本 POC 的结论就不成立。
if ProcessInfo.processInfo.environment["POC_HELLO"] == "1" {
    print("RESULT: hello, sandbox=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none")")
    exit(0)
}

guard FileManager.default.isExecutableFile(atPath: tool.path) else {
    print("RESULT: missing 7zz at \(tool.path)")
    exit(3)
}

let process = Process()
process.executableURL = tool
process.arguments = ["i"]
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = pipe

do {
    try process.run()
} catch {
    print("RESULT: spawn-failed \(error.localizedDescription)")
    exit(4)
}

// 5 秒还没结束就当它卡住了，不要挂着
let deadline = Date().addingTimeInterval(5)
while process.isRunning, Date() < deadline {
    usleep(50_000)
}
if process.isRunning {
    process.terminate()
    print("RESULT: timeout")
    exit(5)
}

let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let head = output.split(separator: "\n").prefix(2).joined(separator: " | ")
print("RESULT: status=\(process.terminationStatus) out=\(head)")
exit(process.terminationStatus == 0 ? 0 : 6)
SWIFT

cat > "$POC/sandbox.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-write</key><true/>
</dict>
</plist>
PLIST

cat > "$POC/inherit.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.inherit</key><true/>
</dict>
</plist>
PLIST

cat > "$POC/empty.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST

make_app() {
    local name="$1"
    local app="$POC/$name.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>com.rrzip.sandboxpoc.$name</string>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
    xcrun swiftc -O -swift-version 5 \
        -target arm64-apple-macos14.0 \
        -o "$app/Contents/MacOS/$name" "$POC/poc.swift" || {
            echo "编译失败：$name" >&2
            exit 7
        }
    cp "$SEVENZIP" "$app/Contents/Resources/7zz"
    chmod +x "$app/Contents/Resources/7zz"
    xattr -cr "$app/Contents/Resources/7zz" 2>/dev/null
    echo "$app"
}

run_case() {
    local label="$1"
    local app="$2"
    local entitlements="$3"
    local tool_entitlements="$4"

    if [ -n "$tool_entitlements" ]; then
        codesign --force --sign "$IDENTITY" --entitlements "$tool_entitlements" \
            "$app/Contents/Resources/7zz" >/dev/null 2>&1
    fi
    if [ -n "$entitlements" ]; then
        codesign --force --sign "$IDENTITY" --entitlements "$entitlements" "$app" >/dev/null 2>&1
    else
        codesign --force --sign "$IDENTITY" "$app" >/dev/null 2>&1
    fi

    echo "--- $label"
    rm -rf "$HOME/Library/Containers/com.rrzip.sandboxpoc.$label" 2>/dev/null
    local out code
    out=$("$app/Contents/MacOS/$(basename "$app" .app)" 2>&1)
    code=$?
    echo "    exit=$code"
    if [ -n "$out" ]; then
        echo "$out" | head -3 | sed 's/^/    /'
    else
        echo "    (无输出)"
    fi
    return 0
}

echo "== 沙盒 POC：扩展内执行 7zz =="
echo "   签名身份：$IDENTITY"
echo ""

SANDBOX_APP=$(make_app "sandboxed")
PLAIN_APP=$(make_app "plain")

run_case "plain" "$PLAIN_APP" "" ""
# 诊断：沙盒 app 本身能不能起来（不 spawn 任何子进程）
echo "--- sandbox-hello"
codesign --force --sign "$IDENTITY" --entitlements "$POC/sandbox.entitlements" "$SANDBOX_APP" >/dev/null 2>&1
hello=$(POC_HELLO=1 "$SANDBOX_APP/Contents/MacOS/sandboxed" 2>&1)
hello_code=$?
echo "    exit=$hello_code out=$hello"
run_case "sandbox" "$SANDBOX_APP" "$POC/sandbox.entitlements" ""
run_case "sandbox-inherit" "$SANDBOX_APP" "$POC/sandbox.entitlements" "$POC/inherit.entitlements"

echo ""
echo "== 判读 =="
if [ "$IS_ADHOC" = "1" ] && [ "$hello_code" -ne 0 ]; then
    echo "ad-hoc 签名无法启用 App Sandbox（sandbox-hello 就 exit=${hello_code}，SIGTRAP）。"
    echo "这组实验在拿到 Developer ID 之前跑不出结论——不是「沙盒不行」，是「无法验」。"
    echo "拿到证书后：IDENTITY=\"Developer ID Application: …\" ./scripts/poc-sandbox.sh"
    exit 3
fi
echo "plain 通过、sandbox 失败、sandbox-inherit 通过 → 公证可行，7zz 必须带 inherit 签名"
echo "sandbox 与 sandbox-inherit 都失败            → 执行层要改成 XPC 回主 app"
exit 0
