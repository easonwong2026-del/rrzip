// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  ArchiveService.swift
//  rrzip
//
//  统一的归档访问入口。打开、批量解压、暂存导出、Quick Look 都从这里走，
//  不再各自决定用 libarchive 还是 7-Zip。
//
//  只依赖 Foundation 与 Archive / FormatDetector，好让快速查看扩展也能编进去。
//

import Foundation

/// 目标已存在同名文件时的处理方式。
/// 只有「跳过」和「覆盖」两档：访达右键没有确认界面，
/// 自动改名需要先解到临时目录再合并，成本高，留给主程序的选择性解压去做。
enum ArchiveConflictPolicy: String, Codable, Sendable {
    case overwrite
    case skip
}

enum ArchiveService {

    /// 起始引擎顺序：磁盘映像这类 libarchive 读不了的交给 7-Zip 先试
    static func engineOrder(for url: URL) -> [ArchiveEngine] {
        FormatDetector.prefersSevenZip(url) ? [.sevenZip, .libarchive] : [.libarchive, .sevenZip]
    }

    static func list(_ url: URL, password: String?, jobID: UUID? = nil) throws -> [ArchiveEntry] {
        try listWithEngine(url, password: password, jobID: jobID).entries
    }

    /// 返回实际列目录的引擎，供主程序保留已选定的归档读取路径。
    static func listWithEngine(_ url: URL, password: String?, jobID: UUID? = nil)
        throws -> (entries: [ArchiveEntry], engine: ArchiveEngine) {
        try TaskRegistry.checkCancellation(jobID)
        var lastError: Error?
        for engine in engineOrder(for: url) where engine.isAvailable {
            do {
                let entries = try list(url, using: engine, password: password, jobID: jobID)
                try TaskRegistry.checkCancellation(jobID)
                return (entries, engine)
            } catch ArchiveError.cancelled {
                throw ArchiveError.cancelled
            } catch ArchiveError.needsPassword {
                // 系统 libarchive 不支持 7z 头加密。收到密码后仅为这种格式走 7zz。
                if retriesEncryptedSevenZip(url, password: password, after: engine) {
                    lastError = ArchiveError.needsPassword
                    continue
                }
                throw ArchiveError.needsPassword
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ArchiveError.engineUnavailable
    }

    private static func list(_ url: URL, using engine: ArchiveEngine, password: String?, jobID: UUID?)
        throws -> [ArchiveEntry] {
        switch engine {
        case .libarchive:
            return try InProcessArchive.list(url, passphrase: password, isCancelled: {
                jobID.map { TaskRegistry.wasCancelled($0) } ?? false
            })
        case .sevenZip:
            return try SevenZip.list(url, password: password, jobID: jobID)
        }
    }

    private static func retriesEncryptedSevenZip(_ url: URL, password: String?, after engine: ArchiveEngine) -> Bool {
        engine == .libarchive && password?.isEmpty == false && SevenZip.isAvailable
            && FormatDetector.detect(url)?.format.id == "7zip"
    }

    /// 同时超过 50 GiB 和 200 倍才阻断，为合法的大归档和高压缩率数据各留余量。
    static func validateExpansion(entries: [ArchiveEntry], compressedSize: Int64?) throws {
        guard let compressedSize, compressedSize > 0 else { return }
        let total = entries.reduce(0.0) { $0 + ($1.isDirectory ? 0 : Double(max(0, $1.size))) }
        if total > 50 * 1024 * 1024 * 1024, total / Double(compressedSize) > 200 {
            throw ArchiveError.excessiveExpansion
        }
    }

    static func validateExtraction(entries: [ArchiveEntry], compressedSize: Int64?) throws {
        var links: [(path: String, target: String)] = []
        for entry in entries {
            try ArchivePathGuard.validateRelative(entry.path)
            if entry.isSymlink {
                // 某些 7-Zip 格式只列出链接模式。目标无法核查时拒绝整包解压。
                guard let target = entry.symlinkTarget else { throw ArchiveError.unsafePath(entry.path) }
                links.append((entry.path, target))
            }
        }
        if !links.isEmpty {
            try ArchivePathGuard.validateSymlinks(links, entryPaths: entries.map(\.path))
        }
        try validateExpansion(entries: entries, compressedSize: compressedSize)
    }

    /// 解压。`entries` 为空表示全部。起始引擎失败时换另一个再试一次
    /// （加密 7z 在 libarchive 下会直接报 header is encrypted）。
    /// `onConflict` 决定目标已存在同名文件时怎么办：
    /// 主程序默认覆盖（用户主动解压，行为不变），访达右键传 `.skip`——
    /// 右键动作没有进度与确认，静默覆盖等于让用户丢文件。
    static func extract(_ url: URL, entries: [String], to destination: URL,
                        password: String?,
                        onConflict: ArchiveConflictPolicy = .overwrite,
                        jobID: UUID? = nil,
                        preferredEngine: ArchiveEngine? = nil,
                        onProgress: (@Sendable (Double) -> Void)? = nil,
                        validateSelection: Bool = false) throws {
        for entry in entries {
            try ArchivePathGuard.validateRelative(entry)
        }
        try TaskRegistry.checkCancellation(jobID)
        var engine = preferredEngine
        var compressedSize: Int64?
        let preflight = entries.isEmpty || validateSelection
        if preflight {
            let inspected = try listWithEngine(url, password: password, jobID: jobID)
            // 分卷片段的字节数不能当成整组压缩大小。
            if FormatDetector.detectByExtension(url)?.split == nil {
                compressedSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            }
            try validateExtraction(entries: inspected.entries, compressedSize: compressedSize)
            engine = inspected.engine
        }

        var lastError: Error?
        let order = engine.map { [$0, $0 == .libarchive ? .sevenZip : .libarchive] }
            ?? engineOrder(for: url)
        for candidate in order where candidate.isAvailable {
            try TaskRegistry.checkCancellation(jobID)
            if preflight, candidate != engine {
                let inspected = try list(url, using: candidate, password: password, jobID: jobID)
                try validateExtraction(entries: inspected, compressedSize: compressedSize)
            }
            try TaskRegistry.checkCancellation(jobID)
            do {
                switch candidate {
                case .libarchive:
                    try Tar.extract(url, entries: entries, to: destination,
                                     passphrase: password, keepExisting: onConflict == .skip,
                                     jobID: jobID)
                case .sevenZip:
                    try SevenZip.extract(url, entries: entries, to: destination,
                                         password: password, skipExisting: onConflict == .skip,
                                         jobID: jobID, onProgress: onProgress)
                }
                return
            } catch ArchiveError.cancelled {
                // 用户取消不是「这个引擎不行」。被当成引擎失败去换下一个的话，
                // 取消会变成「再战一次」——任务卡住，用户还得再按一遍。
                throw ArchiveError.cancelled
            } catch ArchiveError.needsPassword {
                if retriesEncryptedSevenZip(url, password: password, after: candidate) {
                    lastError = ArchiveError.needsPassword
                    continue
                }
                throw ArchiveError.needsPassword
            } catch ArchiveError.unsafePath(let bad) {
                // 安全拦截禁止回退到另一个引擎重试
                throw ArchiveError.unsafePath(bad)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ArchiveError.tool("解压失败：\(url.lastPathComponent)")
    }

    /// 完整性校验：只有 7-Zip 能从头到尾 CRC 一遍
    static func verify(_ url: URL, password: String? = nil, jobID: UUID? = nil) throws {
        try TaskRegistry.checkCancellation(jobID)
        guard SevenZip.isAvailable else { throw ArchiveError.engineUnavailable }
        try SevenZip.verify(url, password: password, jobID: jobID)
    }

    /// 这个包本机能不能开：格式识别 + 引擎可用性
    static func canOpen(_ url: URL) -> Bool {
        switch OpenGate.decide(url) {
        case .open(let detection):
            return detection.format.sevenZipType != nil ? SevenZip.isAvailable : true
        case .unrecognized, .unsupported:
            return false
        }
    }
}

// MARK: - 系统「服务」入口

/// 服务菜单（App.swift 的 `extractHereWithRrzip`）解压时的落点与冲突策略。
///
/// 与访达右键的「解压到此处」对齐：解到包所在目录，同名文件一律跳过。
///
/// 单独立一个类型不是为了好看：这条入口原先直接调 `ArchiveService.extract`，
/// 而那个方法的默认策略是 `.overwrite`，等于用户在访达里点「用 rrzip 解压到此处」
/// 就把同目录里同名文件静默换掉了。服务入口没有确认界面、没有进度、没有回滚，
/// 替用户做这个决定就是丢数据。
///
/// 抽出来还多一个好处：`App.swift` 不在测试编译范围内，
/// 逻辑留在这里才能真正被测试覆盖到（见 Tests/SettingsTests.swift）。
struct ServiceExtractPlan: Equatable, Sendable {
    let destination: URL
    let onConflict: ArchiveConflictPolicy
}

enum ServiceExtraction {

    /// 服务入口的固定语义：解到包旁边，已存在的同名文件不碰
    static func plan(for archive: URL) -> ServiceExtractPlan {
        ServiceExtractPlan(destination: archive.deletingLastPathComponent(),
                           onConflict: .skip)
    }

    /// 服务入口执行解压。`password` 目前恒为 nil（服务菜单收不到密码），
    /// 留参数是为了和 ArchiveService.extract 的签名对齐，不额外造分支。
    static func extract(_ archive: URL, password: String? = nil) throws {
        let plan = plan(for: archive)
        try ArchiveService.extract(archive, entries: [], to: plan.destination,
                                   password: password, onConflict: plan.onConflict)
    }
}
