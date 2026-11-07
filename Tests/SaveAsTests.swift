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
