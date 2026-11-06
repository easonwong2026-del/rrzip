// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  JobKit.swift
//  ArchiveFinder
//
//  访达右键任务的「计划层」：算目标目录、定冲突策略、拼通知文案。
//  不执行、不写盘、不碰 AppKit，全部分支都能在单元测试里跑到。
//  设置结构在 Sources/FinderSettings.swift（主程序也要读写），真正干活的在 JobRunner.swift。
//

import Foundation

// MARK: - 计划

/// 一个包解到哪儿、撞名怎么办
struct PlannedExtraction: Equatable, Sendable {
    let archive: URL
    let destination: URL
    let onConflict: ArchiveConflictPolicy
}

enum FinderJobPlanner {

    /// 目标目录重名就递增：包名 2、包名 3…
    /// `avoiding` 用来在同一次多选里预留位置——两个包都叫 a，不能都解到 a/
    static func uniqueDirectory(_ url: URL, avoiding reserved: Set<String> = []) -> URL {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        var candidate = url
        var index = 2
        while fm.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    static func planExtraction(of archives: [URL], mode: FinderSettings.ExtractStrategy)
        -> [PlannedExtraction] {
        var reserved: Set<String> = []
        var plans: [PlannedExtraction] = []

        for archive in archives {
            let destination: URL
            let policy: ArchiveConflictPolicy

            switch mode {
            case .here:
                // 解到当前目录，同名文件一律跳过而不是覆盖
                destination = archive.deletingLastPathComponent()
                policy = .skip
            case .newFolder:
                let parent = archive.deletingLastPathComponent()
                let base = archive.deletingPathExtension().lastPathComponent
                let name = base.isEmpty ? "归档" : base
                destination = uniqueDirectory(
                    parent.appendingPathComponent(name, isDirectory: true),
                    avoiding: reserved)
                policy = .skip
            }

            reserved.insert(destination.path)
            plans.append(PlannedExtraction(archive: archive,
                                           destination: destination,
                                           onConflict: policy))
        }
        return plans
    }
}

// MARK: - 结果与文案

struct JobOutcome: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let name: String
        let reason: String
    }

    var succeeded: [String] = []
    /// 因同名被跳过的文件数（不是包数）——一个包里跳过 3 个，仍算这个包成功
    var skippedFiles: Int = 0
    var needsPassword: [String] = []
    var failed: [Failure] = []
    var destination: URL?

    var isClean: Bool { skippedFiles == 0 && needsPassword.isEmpty && failed.isEmpty }
}

enum FinderNoticeText {

    /// 通知标题：先给结论，数字放后面
    static func title(for outcome: JobOutcome, verb: String) -> String {
        if !outcome.needsPassword.isEmpty {
            return "需要密码 · \(outcome.needsPassword[0])"
        }
        if outcome.failed.isEmpty, !outcome.succeeded.isEmpty {
            return outcome.skippedFiles > 0
                ? "\(verb)完成 \(outcome.succeeded.count) 个，跳过 \(outcome.skippedFiles) 个同名文件"
                : "\(verb)完成 · \(outcome.succeeded.count) 个"
        }
        if !outcome.succeeded.isEmpty {
            return "\(verb)完成 \(outcome.succeeded.count) 个，\(outcome.failed.count) 个失败"
        }
        if let first = outcome.failed.first {
            return "\(verb)失败 · \(first.name)"
        }
        return "\(verb)未执行"
    }

    /// 副标题：优先给失败原因，其次给落点
    static func body(for outcome: JobOutcome) -> String? {
        if !outcome.needsPassword.isEmpty {
            return "加密包需要在 rrzip 里输入密码后再解压"
        }
        if let first = outcome.failed.first {
            return first.reason
        }
        if let destination = outcome.destination {
            return "位置：\(destination.lastPathComponent)/"
        }
        return nil
    }

    /// 一行摘要，进日志与设置页
    static func detail(for outcome: JobOutcome) -> String {
        var lines: [String] = []
        if !outcome.succeeded.isEmpty { lines.append("完成 \(outcome.succeeded.count)") }
        if outcome.skippedFiles > 0 { lines.append("跳过 \(outcome.skippedFiles) 个同名文件") }
        if !outcome.needsPassword.isEmpty { lines.append("需要密码 \(outcome.needsPassword.count)") }
        if !outcome.failed.isEmpty { lines.append("失败 \(outcome.failed.count)") }
        return lines.isEmpty ? "无动作" : lines.joined(separator: " · ")
    }
}
