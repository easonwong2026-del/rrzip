// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  「另存为」安全提交。以前是 removeItem + copyItem + try?：
//  复制失败时原目标已经没了，而且没有任何提示。
//  这里全部用真实文件跑，专挑失败路径。

import Foundation

func runSaveAsTests() {
    let fm = FileManager.default
    let root = fixtures.appendingPathComponent("save-as", isDirectory: true)
    try? fm.removeItem(at: root)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
        expect(false, "准备另存为测试目录", "\(error)")
        return
    }

    /// 用户目录里不该留下自己造的暂存文件
    func leftovers() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(".rrzip-save-") }
    }
    func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<读不出来>"
    }

    print("另存为：安全提交")
    do {
        let src = root.appendingPathComponent("payload.txt")
        try "PAYLOAD\n".write(to: src, atomically: true, encoding: .utf8)

        // 1. 目标不存在：直接成功
        let fresh = root.appendingPathComponent("fresh.txt")
        try SafeSave.commit(src, to: fresh)
        expect(text(fresh) == "PAYLOAD\n", "目标不存在时正常写入", text(fresh))

        // 2. 目标已存在：整份替换，不留旧文件的尾巴
        let existing = root.appendingPathComponent("existing.txt")
        try "OLD-CONTENT-IS-LONG\n".write(to: existing, atomically: true, encoding: .utf8)
        try SafeSave.commit(src, to: existing)
        expect(text(existing) == "PAYLOAD\n", "覆盖后是完整的新内容", text(existing))
        expect(leftovers().isEmpty, "成功后不留暂存文件", "\(leftovers())")

        // 3. 临时副本准备失败：原目标一个字节都不能动，错误不能被吞掉
        let broken = root.appendingPathComponent("broken.txt")
        try "BROKEN\n".write(to: broken, atomically: true, encoding: .utf8)
        chmod(broken.path, 0o000)
        let keep = root.appendingPathComponent("keep.txt")
        try "USER-ORIGINAL\n".write(to: keep, atomically: true, encoding: .utf8)
        var stagingFailed = false
        do {
            try SafeSave.commit(broken, to: keep)
        } catch {
            stagingFailed = true
        }
        chmod(broken.path, 0o644)
        expect(stagingFailed, "源不可读时抛错，不静默成功")
        expect(text(keep) == "USER-ORIGINAL\n", "失败时目标内容原样保留", text(keep))
        expect(leftovers().isEmpty, "失败后不留暂存文件", "\(leftovers())")

        // 4. 目标是目录：提交失败，目录和里面的文件都不能被动
        let dirTarget = root.appendingPathComponent("folder-target", isDirectory: true)
        try fm.createDirectory(at: dirTarget, withIntermediateDirectories: true)
        let inside = dirTarget.appendingPathComponent("inner.txt")
        try "INNER\n".write(to: inside, atomically: true, encoding: .utf8)
        var commitFailed = false
        do {
            try SafeSave.commit(src, to: dirTarget)
        } catch {
            commitFailed = true
        }
        expect(commitFailed, "目标是目录时抛错")
        expect(text(inside) == "INNER\n", "失败时目录内容不变", text(inside))
        expect(fm.fileExists(atPath: dirTarget.path), "失败时目录本身还在")
        expect(leftovers().isEmpty, "目录目标失败后不留暂存文件", "\(leftovers())")

        // 5. 中文、空格、组合字符：名字原样落盘
        let unicodeName = "带 空格 与 é 的 文件.txt"
        let src2 = root.appendingPathComponent("源 文件 é.txt")
        try "UNICODE\n".write(to: src2, atomically: true, encoding: .utf8)
        let unicodeTarget = root.appendingPathComponent(unicodeName)
        try SafeSave.commit(src2, to: unicodeTarget)
        expect(text(unicodeTarget) == "UNICODE\n", "中文与空格文件名正常保存", text(unicodeTarget))
        expect(text(root.appendingPathComponent("源 文件 é.txt")) == "UNICODE\n",
               "源文件名里的组合字符没被改写")

        // 6. 覆盖中文名目标：旧内容不残留
        try "OLD\n".write(to: unicodeTarget, atomically: true, encoding: .utf8)
        try SafeSave.commit(src, to: unicodeTarget)
        expect(text(unicodeTarget) == "PAYLOAD\n", "中文名目标可安全覆盖", text(unicodeTarget))
    } catch {
        expect(false, "另存为安全提交 抛出异常", "\(error)")
    }
    expect(leftovers().isEmpty, "全部用例结束后没有暂存残留", "\(leftovers())")

    print("另存为：多选不隐式导出")
    // 单个文件的窗口才允许「另存为」；多选交给「解压选中项」/ 暂存区
    expect(!SaveAsFlow.allowsSingleFileExport(selectionCount: 0, isDirectory: false),
           "未选中时不可另存为")
    expect(SaveAsFlow.allowsSingleFileExport(selectionCount: 1, isDirectory: false),
           "单选文件时可另存为")
    expect(!SaveAsFlow.allowsSingleFileExport(selectionCount: 2, isDirectory: false),
           "多选时不提供单文件另存为")
    expect(!SaveAsFlow.allowsSingleFileExport(selectionCount: 1, isDirectory: true),
           "文件夹不可另存为")
}

/// 后台保存：复制不在主线程，期间要挡住缓存清理，结束后登记必须归零。
/// 这条链路以前是「主线程 copyItem + 没有任何登记」：
/// 清缓存正好撞上来时会把源副本删掉，界面只报一句「保存失败」。
func runSaveAsBackgroundTests() {
    let fm = FileManager.default
    let root = fixtures.appendingPathComponent("save-as-bg", isDirectory: true)
    try? fm.removeItem(at: root)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
        expect(false, "准备后台保存测试目录", "\(error)")
        return
    }
    ScratchUsage.shared.reset()

    func leftovers() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(".rrzip-save-") }
    }
    func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<读不出来>"
    }

    print("另存为：后台复制与缓存清理")
    let src = root.appendingPathComponent("payload.txt")
    try? "PAYLOAD\n".write(to: src, atomically: true, encoding: .utf8)

    // 1. 登记期间清缓存必须整体跳过，一个文件都不能动
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    let cached = scratch.appendingPathComponent("cached.txt")
    try? "CACHED\n".write(to: cached, atomically: true, encoding: .utf8)

    ScratchUsage.shared.beginWork()
    let blocked = CacheMaintenance.purge([scratch], busy: false)
    expect(blocked.blocked, "有保存任务在跑时清缓存被拦住")
    expect(blocked.freedBytes == 0, "被拦住时不计已清理字节", "\(blocked.freedBytes)")
    expect(fm.fileExists(atPath: cached.path), "被拦住时临时文件还在")

    ScratchUsage.shared.endWork()
    let after = CacheMaintenance.purge([scratch], busy: false)
    expect(!after.blocked, "任务结束后清缓存不再被拦")
    expect(after.freedBytes > 0, "任务结束后临时文件被清掉", "\(after.freedBytes)")
    expect(!fm.fileExists(atPath: cached.path), "临时文件确实删掉了")

    // 2. 后台保存成功：内容落盘、登记归零、不留暂存
    let dst = root.appendingPathComponent("saved.txt")
    var done = false
    var failure: String?
    Task { @MainActor in
        do { try await SafeSave.commitInBackground(src, to: dst) } catch { failure = error.localizedDescription }
        done = true
    }
    expect(waitUntil(10) { done }, "后台保存完成")
    expect(failure == nil, "后台保存没有抛错", failure ?? "")
    expect(text(dst) == "PAYLOAD\n", "后台保存写出的内容正确", text(dst))
    expect(!ScratchUsage.shared.isWorking, "成功后 worker 归零")
    expect(leftovers().isEmpty, "成功后没有暂存残留", "\(leftovers())")

    // 3. 后台保存失败：目标不动、登记也要归零（不能把计数漏在那里）
    let broken = root.appendingPathComponent("broken.txt")
    try? "BROKEN\n".write(to: broken, atomically: true, encoding: .utf8)
    chmod(broken.path, 0o000)
    let keep = root.appendingPathComponent("keep.txt")
    try? "USER-ORIGINAL\n".write(to: keep, atomically: true, encoding: .utf8)
    var failed = false
    var failedDone = false
    Task { @MainActor in
        do { try await SafeSave.commitInBackground(broken, to: keep) } catch { failed = true }
        failedDone = true
    }
    expect(waitUntil(10) { failedDone }, "后台保存失败路径结束")
    chmod(broken.path, 0o644)
    expect(failed, "源不可读时后台保存抛错")
    expect(text(keep) == "USER-ORIGINAL\n", "失败后目标内容原样保留", text(keep))
    expect(!ScratchUsage.shared.isWorking, "失败后 worker 也归零")
    expect(leftovers().isEmpty, "失败后没有暂存残留", "\(leftovers())")

    // 4. 交错：复制进行中清缓存
    // 复制本机同卷可能一瞬完成，抓不到窗口就只打一行说明——
    // 「有 worker 就整体跳过」这条契约由第 1 组用例确定性地覆盖。
    let tree = root.appendingPathComponent("tree", isDirectory: true)
    try? fm.createDirectory(at: tree, withIntermediateDirectories: true)
    for index in 0..<600 {
        let file = tree.appendingPathComponent("f\(index).txt")
        try? Data(repeating: UInt8(index % 251), count: 4096).write(to: file)
    }
    let treeDst = root.appendingPathComponent("tree-saved", isDirectory: true)
    var treeDone = false
    Task { @MainActor in
        try? await SafeSave.commitInBackground(tree, to: treeDst)
        treeDone = true
    }
    if waitUntil(5, interval: 0.002, { ScratchUsage.shared.isWorking }) {
        let during = CacheMaintenance.purge([scratch], busy: false)
        expect(during.blocked, "复制进行中清缓存被拦住")
    } else {
        print("  · 复制快到来不及观察，跳过错峰断言（契约已由第 1 组覆盖）")
    }
    expect(waitUntil(30) { treeDone }, "目录后台保存完成")
    expect(fm.fileExists(atPath: treeDst.appendingPathComponent("f599.txt").path),
           "目录内容完整复制")
    expect(!ScratchUsage.shared.isWorking, "交错结束后 worker 归零")
    expect(leftovers().isEmpty, "交错结束后没有暂存残留", "\(leftovers())")

    print("另存为：后台保存完毕")
}
