// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  测试脚手架：断言计数与样例包路径。
//  拆文件之后各测试文件共用这一份，别再各写一遍 expect。

import Foundation

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name) \(detail())")
    }
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])

func finish() {
    print("")
    print(failures == 0 ? "全部通过（\(checks) 项）" : "失败 \(failures)/\(checks)")
    exit(failures == 0 ? 0 : 1)
}
