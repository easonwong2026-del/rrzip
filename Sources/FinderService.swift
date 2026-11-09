// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  FinderService.swift
//  rrzip
//
//  访达右键「服务」的执行体。
//
//  这条路径以前直接起 Task（甚至同步跑在主线程上），既不在任务队列里，
//  也没有任何归属，⌘Q 时完全看不见它。现在统一收进 FormalWriteLedger：
//  调用即登记（同步），结束后注销；退出协调对这类工作只等不杀。
//
//  压缩一律走 ArchiveModel.writeArchive：先写隐藏的临时文件，成功后再换上正式名，
//  所以中途失败 / 退出不会在用户目录里留下半截 ZIP。
//  解压保持原语义：同名文件跳过，取消时已写出的部分文件留在目标目录，如实上报。
//

import Foundation

/// 访达「分别压缩」的结果：成功的产物和失败的源文件
struct FinderCompressOutcome: Sendable {
    var made: [URL] = []
    var failed: [String] = []
}

/// 访达「合并压缩」的结果：成功给产物，失败给可展示的原因
struct FinderCompressResult: Sendable {
    var output: URL?
    var failure: String?
}

enum FinderService {
    /// 分别压缩：每个源各生成一个 ZIP，已存在同名则自动加序号。
    /// 返回的 Task 已经在账本上登记，调用方不必再管退出协调。
    @discardableResult
    static func compressEach(_ urls: [URL]) -> Task<FinderCompressOutcome, Never> {
        let token = FormalWriteLedger.shared.begin(
            .finderService, label: "访达服务 · 分别压缩 \(urls.count) 项"
        )
        return Task {
            defer { FormalWriteLedger.shared.end(token) }
            var outcome = FinderCompressOutcome()
            for url in urls {
                let folder = url.deletingLastPathComponent()
                let name = url.deletingPathExtension().lastPathComponent
                let output = ArchiveModel.uniqueOutput(
                    folder.appendingPathComponent(name.isEmpty ? "归档" : name)
                        .appendingPathExtension("zip")
                )
                do {
                    try ArchiveModel.writeArchive(at: output, from: [url], format: .zip,
                                                  password: "", volume: nil)
                    outcome.made.append(output)
                } catch {
                    // 单个失败不影响其他文件，但必须如实报出来
                    outcome.failed.append(url.lastPathComponent)
                }
            }
            return outcome
        }
    }

    /// 合并压缩：多个源压成一个 ZIP。失败时带可展示的原因。
    @discardableResult
    static func compressMerged(_ urls: [URL]) -> Task<FinderCompressResult, Never> {
        let token = FormalWriteLedger.shared.begin(
            .finderService, label: "访达服务 · 压缩 \(urls.count) 项"
        )
        let base = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "归档"
        let folder = urls[0].deletingLastPathComponent()
        let output = ArchiveModel.uniqueOutput(
            folder.appendingPathComponent(base.isEmpty ? "归档" : base).appendingPathExtension("zip")
        )
        return Task {
            defer { FormalWriteLedger.shared.end(token) }
            do {
                try ArchiveModel.writeArchive(at: output, from: urls, format: .zip,
                                              password: "", volume: nil)
                return FinderCompressResult(output: output)
            } catch {
                return FinderCompressResult(failure: error.localizedDescription)
            }
        }
    }

    /// 解压到各自所在的目录（同名文件跳过）。返回失败的包名。
    @discardableResult
    static func extract(_ urls: [URL]) -> Task<[String], Never> {
        let token = FormalWriteLedger.shared.begin(
            .finderService, label: "访达服务 · 解压 \(urls.count) 项"
        )
        return Task {
            defer { FormalWriteLedger.shared.end(token) }
            var failed: [String] = []
            for url in urls {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ServiceExtraction.extract(url)
                    }.value
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            return failed
        }
    }
}
