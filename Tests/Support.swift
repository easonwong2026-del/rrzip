// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  测试脚手架：断言计数与样例包路径。
//  拆文件之后各测试文件共用这一份，别再各写一遍 expect。

import Foundation

private final class TestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private var failures = 0

    func record(_ passed: Bool) {
        lock.withLock {
            checks += 1
            if !passed { failures += 1 }
        }
    }

    var total: (checks: Int, failures: Int) {
        lock.withLock { (checks, failures) }
    }
}

private let testCounts = TestCounts()

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    testCounts.record(condition)
    print(condition ? "  ✓ \(name)" : "  ✗ \(name) \(detail())")
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])

/// 跑主线程 runloop 直到条件成立或超时。测试里等队列里的异步任务用，
/// 别用固定 sleep：机器快慢不一样，固定等待不是慢就是脆。
/// interval 可调小，用来抓「进程刚好在跑」这种短窗口。
@discardableResult
func waitUntil(_ seconds: TimeInterval = 15, interval: TimeInterval = 0.02,
               _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    }
    return condition()
}

/// 暂存打包用的临时目录（rrzip-stash-*）。取消 / 失败后不该留下任何一个。
func stashTempDirs() -> Set<String> {
    let tmp = FileManager.default.temporaryDirectory
    let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
    return Set(names.filter { $0.hasPrefix("rrzip-stash-") })
}

func finish() {
    let (checks, failures) = testCounts.total
    print("")
    print(failures == 0 ? "全部通过（\(checks) 项）" : "失败 \(failures)/\(checks)")
    exit(failures == 0 ? 0 : 1)
}
