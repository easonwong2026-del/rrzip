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

    /// 列目录。密码缺失直接抛 needsPassword，不换引擎——换了也一样要密码。
    static func list(_ url: URL, password: String?) throws -> [ArchiveEntry] {
        var lastError: Error?
        for engine in engineOrder(for: url) {
            do {
                switch engine {
                case .libarchive:
                    return try Tar.list(url, passphrase: password)
                case .sevenZip:
                    return try SevenZip.list(url, password: password)
                }
            } catch ArchiveError.needsPassword {
                throw ArchiveError.needsPassword
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ArchiveError.tool("无法读取 \(url.lastPathComponent)")
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
                        onProgress: (@Sendable (Double) -> Void)? = nil) throws {
        var lastError: Error?
        for engine in engineOrder(for: url) {
            do {
                switch engine {
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
                throw ArchiveError.needsPassword
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ArchiveError.tool("解压失败：\(url.lastPathComponent)")
    }

    /// 完整性校验：只有 7-Zip 能从头到尾 CRC 一遍
    static func verify(_ url: URL) throws {
        guard SevenZip.isAvailable else { throw ArchiveError.engineUnavailable }
        try SevenZip.verify(url)
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
