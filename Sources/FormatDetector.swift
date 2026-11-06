// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//
//  FormatDetector.swift
//  rrzip
//
//  按后缀 + 魔数识别归档格式。
//  识别策略参考 MacPacker 的 ArchiveTypeDetector（GPL-3.0），
//  实现为本项目自行编写，见 NOTICE。
//

import Foundation

/// 识别结果
struct FormatDetection: Hashable {
    enum Source: String {
        case fileExtension
        case magic
    }

    let format: ArchiveFormatSpec
    /// 命中复合后缀时非空，例如 tar.gz
    let compound: CompoundSpec?
    /// 命中的分卷方案
    let split: SplitSpec?
    let source: Source

    /// 详情面板上显示的名字
    var displayName: String {
        if let compound { return compound.name }
        if split != nil { return format.name + "（分卷）" }
        return format.name
    }
}

/// 打开前的统一判定：识别格式 → 判断本机能不能开。
/// 所有入口（⌘O、拖放、访达打开、命令行）都必须走这里，不允许再按后缀前置拦截。
enum OpenGate {
    enum Decision: Equatable {
        case open(FormatDetection)
        case unrecognized
        case unsupported(FormatDetection)
    }

    static func decide(_ url: URL) -> Decision {
        guard let detection = FormatDetector.detect(url) else { return .unrecognized }
        return detection.format.isOpenable ? .open(detection) : .unsupported(detection)
    }
}

enum FormatDetector {
    /// 这些格式交给系统 bsdtar（libarchive）更快更稳；其余走内置 7-Zip
    static let libarchiveFormats: Set<String> = [
        "zip", "zipx", "7zip", "tar", "gzip", "bzip2", "xz", "lzma",
        "cpio", "xar", "pkg", "iso", "rar", "lha", "ar", "rpm", "cab", "z"
    ]

    /// 按后缀识别：复合后缀 → 分卷 → 普通格式
    static func detectByExtension(_ url: URL) -> FormatDetection? {
        let name = url.lastPathComponent.lowercased()

        // 1. 复合后缀，长后缀优先（tar.gz 要压过 gz）
        let compounds = FormatCatalog.compounds
            .flatMap { spec in spec.extensions.map { (spec, $0.lowercased()) } }
            .sorted { $0.1.count > $1.1.count }
        for (spec, ext) in compounds where name.hasSuffix("." + ext) {
            guard let base = FormatCatalog.formats.first(where: { $0.id == spec.components.first }) else { continue }
            return FormatDetection(format: base, compound: spec, split: nil, source: .fileExtension)
        }

        // 2. 分卷片段（x.zip.001 / x.z01）
        for split in FormatCatalog.splits
        where name.range(of: split.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            guard let base = FormatCatalog.formats.first(where: { $0.id == split.format }) else { continue }
            return FormatDetection(format: base, compound: nil, split: split, source: .fileExtension)
        }

        // 3. 普通后缀
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if let spec = FormatCatalog.formats.first(where: { $0.extensions.contains(ext) }) {
            return FormatDetection(format: spec, compound: nil, split: nil, source: .fileExtension)
        }
        return nil
    }

    /// 按魔数识别：读头部 64 KB 与尾部 512 B
    static func detectByMagic(_ url: URL) -> FormatDetection? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let headerData = try? handle.read(upToCount: 65536), !headerData.isEmpty else { return nil }
        let header = [UInt8](headerData)

        var trailer: [UInt8] = []
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64, size > 0 {
            let tailSize = min(Int64(512), size)
            if (try? handle.seek(toOffset: UInt64(size - tailSize))) != nil,
               let tailData = try? handle.read(upToCount: Int(tailSize)) {
                trailer = [UInt8](tailData)
            }
        }

        for spec in FormatCatalog.formats where !spec.rules.isEmpty {
            for group in spec.rules where matches(group, header: header, trailer: trailer) {
                return FormatDetection(format: spec, compound: nil, split: nil, source: .magic)
            }
        }
        return nil
    }

    /// 先看后缀，后缀说不清再看内容
    static func detect(_ url: URL) -> FormatDetection? {
        if let byExtension = detectByExtension(url) { return byExtension }
        return detectByMagic(url)
    }

    /// 该文件该用哪个引擎先试
    static func prefersSevenZip(_ url: URL) -> Bool {
        guard let detection = detect(url) else { return false }
        return !libarchiveFormats.contains(detection.format.id)
    }

    // MARK: - 规则求值

    private static func matches(_ group: MagicGroup, header: [UInt8], trailer: [UInt8]) -> Bool {
        if group.matchAll {
            return group.tests.allSatisfy { matches($0, header: header, trailer: trailer) }
        }
        return group.tests.contains { matches($0, header: header, trailer: trailer) }
    }

    private static func matches(_ test: MagicTest, header: [UInt8], trailer: [UInt8]) -> Bool {
        let buffer = test.fromEnd ? trailer : header
        // fromEnd 的 offset 是从文件末尾起算（512 = 贴尾），换算成缓冲区下标
        let start = test.fromEnd ? buffer.count - test.offset : test.offset
        let end = start + test.bytes.count
        guard start >= 0, end <= buffer.count else { return false }
        return Array(buffer[start..<end]) == test.bytes
    }
}
