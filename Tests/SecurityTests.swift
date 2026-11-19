// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  安全边界与 P0/P1 回归测试：路径穿越、参数注入、复合后缀、空数组保护与退出弹窗状态机。
//

import Foundation

func runSecurityTests() {
    testPathGuardRejectsTraversalAndAbsolute()
    testTarOperandGuardNeutralizesLeadingSwitchAndListfile()
    testUniquePathCompoundExtension()
    testFinderServiceCompressMergedEmptyArraySafe()
    testTerminationPromptingIgnoresPrematureDrain()
}

private func testPathGuardRejectsTraversalAndAbsolute() {
    print("安全 · 路径穿越与绝对路径拦截")
    let unsafePaths = [
        "../escape.txt",
        "a/../../escape.txt",
        "/etc/passwd",
        "\\windows\\system32",
        "foo\0bar.txt",
        ""
    ]
    for bad in unsafePaths {
        var rejected = false
        do {
            try ArchivePathGuard.validateRelative(bad)
        } catch ArchiveError.unsafePath {
            rejected = true
        } catch {}
        expect(rejected, "应拦截不安全路径：\(bad.debugDescription)")
    }

    var accepted = true
    do {
        try ArchivePathGuard.validateRelative("docs/readme.txt")
        try ArchivePathGuard.validateRelative("", allowEmpty: true)
    } catch {
        accepted = false
    }
    expect(accepted, "合法相对路径与允许空前缀应放行")

    let base = URL(fileURLWithPath: "/tmp/rrzip-guard-base", isDirectory: true)
    let inside = base.appendingPathComponent("sub/file.txt")
    let outside = base.appendingPathComponent("../outside.txt")
    expect((try? ArchivePathGuard.validateContained(inside, within: base)) != nil, "目录内子路径放行")
    expect((try? ArchivePathGuard.validateContained(outside, within: base)) == nil, "逃逸父目录路径被拦截")
}

private func testTarOperandGuardNeutralizesLeadingSwitchAndListfile() {
    print("安全 · 命令行选项与 listfile 前缀防护")
    expect(ArchivePathGuard.guardTarOperand("-rf") == "./-rf", "以 - 开头的文件名加 ./ 前缀")
    expect(ArchivePathGuard.guardTarOperand("@secret.txt") == "./@secret.txt", "以 @ 开头的文件名加 ./ 前缀")
    expect(ArchivePathGuard.guardTarOperand("normal.txt") == "normal.txt", "普通文件名保持不变")
}

private func testUniquePathCompoundExtension() {
    print("健壮性 · UniquePath 复合扩展名去重")
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rrzip-unique-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = dir.appendingPathComponent("backup.tar.gz")
    FileManager.default.createFile(atPath: first.path, contents: Data())
    let second = UniquePath.file(first)
    expect(second.lastPathComponent == "backup 2.tar.gz", "复合扩展名应生成 backup 2.tar.gz", "实际：\(second.lastPathComponent)")
}

private func testFinderServiceCompressMergedEmptyArraySafe() {
    print("健壮性 · FinderService.compressMerged 空数组不崩溃")
    let task = FinderService.compressMerged([])
    var result: FinderCompressResult?
    Task { result = await task.value }
    expect(waitUntil(5, { result != nil }), "空数组合并压缩应立即返回结果")
    expect(result?.failure != nil, "空数组合并压缩应返回失败原因而非越界崩溃")
    expect(FormalWriteLedger.shared.count == 0, "空数组不应泄漏 FormalWriteLedger 计数")
}

@MainActor
private final class SecurityStubHost: TerminationHost {
    var pendingJobCount = 0
    var formalWrites = FormalWriteSummary()
    var isWritingScratch = false
    var onWorkDrained: (() -> Void)?
    func beginTerminationWait() {}
    func cancelWorkForTermination() { pendingJobCount = 0 }
    func resumeAfterAbortedTermination() {}
}

private func testTerminationPromptingIgnoresPrematureDrain() {
    print("生命周期 · 退出确认弹窗期间忽略任务排空回调")
    MainActor.assumeIsolated {
        let coordinator = TerminationCoordinator()
        let host = SecurityStubHost()
        host.pendingJobCount = 1
        coordinator.host = host
        coordinator.defersPrompt = true
        var terminations = 0
        var aborts = 0
        coordinator.onTerminate = { terminations += 1 }
        coordinator.onAbort = { aborts += 1 }
        coordinator.ask = { .keepUsing }

        expect(coordinator.requestTermination() == .terminateLater, "有任务时挂起退出")
        expect(coordinator.state == .prompting, "弹窗前进入 prompting 状态")

        // 模拟弹窗尚未点击时后台任务恰好完成触发排空
        host.pendingJobCount = 0
        coordinator.noteWorkDrained()
        expect(terminations == 0, "prompting 期间任务排空不得提前强退")
        expect(coordinator.state == .prompting, "状态仍保持 prompting 等待用户决策")

        coordinator.apply(.keepUsing)
        expect(aborts == 1 && terminations == 0, "用户选择继续使用后正确中止退出")
        expect(coordinator.state == .idle, "状态恢复 idle")
        coordinator.reset()
    }
}
