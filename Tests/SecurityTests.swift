// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  安全边界与 P0/P1 回归测试：路径穿越、参数注入、复合后缀、空数组保护与退出弹窗状态机。
//

import Foundation

func runSecurityTests() {
    testPathGuardRejectsTraversalAndAbsolute()
    testListFileSeparators()
    testSymlinkPreflight()
    testExpansionPreflight()
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

private func testListFileSeparators() {
    print("安全 · listfile 分隔符")
    for path in ["first\nsecond", "first\rsecond", "first\r\nsecond", "first\0second"] {
        do {
            try ArchivePathGuard.validateRelative(path)
            expect(false, "相对路径应拒绝控制分隔符")
        } catch ArchiveError.unsafePath(let value) {
            expect(value == path, "路径检查报告原始非法值")
        } catch { expect(false, "路径检查错误类型", "\(error)") }

        do {
            let url = try ArchivePathGuard.writeListFile(["/absolute/file", path])
            try? FileManager.default.removeItem(at: url)
            expect(false, "listfile 应拒绝控制分隔符")
        } catch ArchiveError.unsafePath(let value) {
            expect(value == path, "listfile 报告原始非法值")
        } catch { expect(false, "listfile 错误类型", "\(error)") }
    }
    do {
        let url = try ArchivePathGuard.writeListFile(["/absolute/path with space", "中文.txt"])
        defer { try? FileManager.default.removeItem(at: url) }
        let content = try String(contentsOf: url, encoding: .utf8)
        expect(content == "/absolute/path with space\n中文.txt\n", "安全的绝对源路径仍能写入 listfile")
    } catch { expect(false, "合法 listfile 写入失败", "\(error)") }
}

private func testSymlinkPreflight() {
    print("安全 · 整包解压软链预检")
    for target in ["/outside", "\\outside", "C:\\outside", "../../outside", "sub/../../../outside", "line\nbreak", ""] {
        do {
            try ArchivePathGuard.validateSymlink(target, at: "dir/link")
            expect(false, "应拒绝越界或非法目标 \(target.debugDescription)")
        } catch ArchiveError.unsafePath {
            expect(true, "拒绝越界或非法目标 \(target.debugDescription)")
        } catch { expect(false, "软链检查错误类型", "\(error)") }
    }
    for target in ["../file", "./file", "sub/../../file", ".."] {
        expect((try? ArchivePathGuard.validateSymlink(target, at: "dir/link")) != nil,
               "放行留在归档根目录内的目标 \(target)")
    }
    expect((try? ArchivePathGuard.validateSymlinks([
        ("dir/forward", "../target"), ("alias", "dir/forward")
    ])) != nil, "放行留在根目录内的多级软链")
    expect((try? ArchivePathGuard.validateSymlinks([
        ("dir/back", ".."), ("alias", "dir/back/../outside")
    ])) == nil, "目标解析穿过其他软链后仍检查解压根目录")
    expect((try? ArchivePathGuard.validateSymlink("../../outside", at: "a\\b/link")) == nil,
           "反斜杠作为普通字符时也不会把包外路径误算成包内")
    expect((try? ArchivePathGuard.validateSymlinks([
        ("dir/alias", ".."), ("dir/alias/nested", "file")
    ])) == nil, "拒绝把另一个软链写到链式父目录下")
    expect((try? ArchivePathGuard.validateSymlinks([
        ("dir/alias", "..")
    ], entryPaths: ["dir/alias/report.txt"])) == nil, "拒绝通过软链父目录落盘普通条目")
    expect((try? ArchivePathGuard.validateSymlinks([
        ("a", "b"), ("b", "a")
    ])) == nil, "超过软链解析上限时阻断预检")
    let unknown = ArchiveEntry(path: "link", size: 1, modified: "", mode: "lrwxrwxrwx")
    do {
        try ArchiveService.validateExtraction(entries: [unknown], compressedSize: 50)
        expect(false, "整包解压应拒绝无法确认目标的软链")
    } catch ArchiveError.unsafePath(let path) {
        expect(path == "link", "无法确认目标的软链报出具体条目")
    } catch { expect(false, "缺失软链目标诊断类型", "\(error)") }
    let fm = FileManager.default
    let root = fixtures.appendingPathComponent("symlink-preflight", isDirectory: true)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("file")
        try Data("contents".utf8).write(to: file)
        let link = source.appendingPathComponent("alias")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "file")
        let good = root.appendingPathComponent("good.tar")
        try Tar.create(at: good, from: [source], format: "tar")
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try ArchiveService.extract(good, entries: [], to: destination, password: nil)
        let target = try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("input/alias").path)
        expect(target == "file", "整包解压保留指向包内的软链")

        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../missing")
        let bad = root.appendingPathComponent("bad.tar")
        try Tar.create(at: bad, from: [source], format: "tar")
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        do {
            try ArchiveService.extract(bad, entries: [], to: blocked, password: nil)
            expect(false, "越界软链应阻断整包解压")
        } catch ArchiveError.unsafePath(let path) {
            expect(path.contains("input/alias"), "整包解压报告对应软链")
        }
        expect(!fm.fileExists(atPath: blocked.path), "拦截发生在写入目标目录前")
    } catch { expect(false, "软链预检集成测试", "\(error)") }
}

private func testExpansionPreflight() {
    print("安全 · 解压体积与膨胀比")
    let limit: Int64 = 50 * 1024 * 1024 * 1024
    func entry(_ size: Int64, path: String = "data") -> ArchiveEntry {
        ArchiveEntry(path: path, size: size, modified: "", mode: "-rw-r--r--")
    }
    do {
        try ArchiveService.validateExpansion(entries: [entry(limit)], compressedSize: 1)
        expect(true, "总大小等于阈值时放行")
        try ArchiveService.validateExpansion(entries: [entry(limit * 2)], compressedSize: limit / 100)
        expect(true, "体积很大且压缩比等于 200 倍时放行")
        try ArchiveService.validateExpansion(entries: [entry(limit), entry(-1)], compressedSize: 1)
        expect(true, "声明大小未知的条目不计入总量")
        try ArchiveService.validateExpansion(entries: [entry(limit * 2)], compressedSize: nil)
        expect(true, "压缩大小未知时没有可比较的比例")
    } catch { expect(false, "宽松体积阈值不应误拦", "\(error)") }

    do {
        try ArchiveService.validateExpansion(entries: [entry(limit), entry(Int64.max, path: "second")],
                                             compressedSize: 1)
        expect(false, "同时超过两个阈值应阻断")
    } catch ArchiveError.excessiveExpansion {
        expect(true, "累加超大声明大小时不会溢出且给出明确错误")
    } catch { expect(false, "异常膨胀错误类型", "\(error)") }
}
