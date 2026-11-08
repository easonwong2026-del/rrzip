// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  SaveAs.swift
//  「另存为」的唯一出口。
//
//  以前三个入口（选中操作条 / 右键菜单 / 预览面板）各写一遍：
//      try? FileManager.default.removeItem(at: destination)
//      try? FileManager.default.copyItem(at: url, to: destination)
//  「先删后拷」+「try?」意味着复制失败 = 原文件已经没了，而且没人知道。
//  实测：源文件不可读时目标直接消失，界面上没有任何提示。
//
//  现在统一成：面板选落点 → 准备好临时副本 → 目标同目录写暂存 → rename(2) 提交。
//  rename 是原子的：要么整份换上去，要么目标原样不动，不存在半截文件。
//  同一套「暂存 + 原子提交」的思路在 FinderSettingsStore 和 commitStaged 里已经用过，
//  这里不另起一套文件管理框架。

import AppKit
import Foundation

enum SaveAsError: LocalizedError {
    /// 临时副本写不出来（源不可读、磁盘满、权限不足）
    case stagingFailed(String)
    /// 暂存已经写好，但换不上目标位置
    case commitFailed(String)

    var errorDescription: String? {
        switch self {
        case .stagingFailed(let reason):
            return "写入临时副本失败：\(reason)"
        case .commitFailed(let reason):
            return "无法写入目标位置：\(reason)"
        }
    }
}

enum SafeSave {

    /// 把 `source` 安全地存到 `destination`。
    ///
    /// - 失败时 `destination` 保持原样（内容和路径都不变）。
    /// - 自己产生的暂存文件一定清掉，不在用户目录里留垃圾。
    /// - 不做「先删目标再复制」，任何分支都不会让目标先消失。
    nonisolated static func commit(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        // 暂存名带随机后缀：同时保存两个同名文件不会互相截断，
        // 失败时也只删自己这一份
        let staging = folder.appendingPathComponent(
            ".rrzip-save-\(UUID().uuidString.prefix(8))-\(destination.lastPathComponent)")

        do {
            // 先落到目标同目录：rename 只在同一个文件系统内可靠，
            // 跨卷（比如从临时目录直接换到外置盘）会失败
            try fm.copyItem(at: source, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw SaveAsError.stagingFailed(error.localizedDescription)
        }

        // rename 覆盖目标：能走到这里说明用户在保存面板里已经明确确认过替换。
        // errno 要在清暂存之前取，removeItem 会把它冲掉。
        guard rename(staging.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: staging)
            throw SaveAsError.commitFailed(reason)
        }
    }

    /// 界面用的版本：复制与提交都在后台线程，主线程只等结果。
    ///
    /// `copyItem` 在本机同卷时很快（APFS 走 clone），但目标是外置盘、网络盘时
    /// 就是实打实的几秒——放在主线程上是整窗转菊花，连取消都点不到。
    ///
    /// 复制期间登记一个 worker：清缓存看到 worker 会整体跳过，
    /// 否则源副本被删掉，`copyItem` 直接失败，用户只看到一句「保存失败」。
    /// 登记带上源路径，自动按预算回收也能认出这个目录正在被读——
    /// 只加计数的话，智能回收看不见它。成功、失败、任务取消都走同一个 defer。
    nonisolated static func commitInBackground(_ source: URL, to destination: URL) async throws {
        ScratchUsage.shared.beginWork(on: source.path)
        defer { ScratchUsage.shared.endWork(on: source.path) }
        try await Task.detached(priority: .userInitiated) {
            try commit(source, to: destination)
        }.value
    }
}

/// 三个界面入口共用的流程：保存面板 → 取临时副本 → 安全提交 → 结果反馈。
@MainActor
enum SaveAsFlow {

    /// 只有「恰好一个普通文件」才走单文件另存为。
    /// 多选以前会静默只存第一个，现在一律交给「解压选中项」或暂存区导出。
    nonisolated static func allowsSingleFileExport(selectionCount: Int,
                                                   isDirectory: Bool) -> Bool {
        selectionCount == 1 && !isDirectory
    }

    /// 单个文件的「另存为」。目录和多选不走这里。
    /// 目录用「解压到文件夹」，多选用暂存区导出，避免隐式只保存第一项。
    static func present(_ entry: ArchiveEntry, model: ArchiveModel) {
        guard allowsSingleFileExport(selectionCount: 1, isDirectory: entry.isDirectory) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.message = "从压缩包导出「\(entry.name)」"
        // 覆盖确认交给系统面板：用户点「替换」才继续，取消则一个字节都不动
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { @MainActor in
            model.errorMessage = nil
            guard let payload = await model.payloadURL(for: entry) else {
                model.errorMessage = "读取「\(entry.name)」失败，没有保存任何文件。\n目标位置未改动。"
                return
            }
            // payloadURL 的交接占用在它返回时就放开了，而下面的 commitInBackground
            // 是 nonisolated async：真正登记源路径还要再过一次调度。这两段之间自己兜住，
            // 保存成功、失败都走这个 defer。
            ScratchUsage.shared.hold(payload)
            defer { ScratchUsage.shared.release(payload) }
            do {
                // 复制不在主线程：大文件 + 外置盘时不会把窗口卡住
                try await SafeSave.commitInBackground(payload, to: destination)
                model.notice = "已保存「\(destination.lastPathComponent)」"
            } catch {
                model.errorMessage = "保存「\(entry.name)」失败。\n\(error.localizedDescription)\n目标位置未改动。"
            }
        }
    }
}
