// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  UniquePath.swift
//  rrzip
//
//  「重名就加序号」的唯一实现。
//  主程序（新建压缩包、解锁后续解压）和访达扩展（解到包名文件夹）都要用，
//  以前两边各写了一份，改规则时要记得改两处。
//

import Darwin
import Foundation

enum UniquePath {

    private static let maxAttempts = 10_000

    /// 拆分复合扩展名（如 `backup.tar.gz` → `("backup", "tar.gz")`），普通文件按单后缀拆分
    private static func splitNameAndExtension(_ filename: String) -> (base: String, ext: String) {
        let lower = filename.lowercased()
        let compoundExts = FormatCatalog.compounds
            .flatMap(\.extensions)
            .sorted { $0.count > $1.count }
        for compound in compoundExts {
            let suffix = "." + compound
            if lower.hasSuffix(suffix), filename.count > suffix.count {
                let splitIndex = filename.index(filename.endIndex, offsetBy: -suffix.count)
                return (String(filename[..<splitIndex]), String(filename[filename.index(after: splitIndex)...]))
            }
        }
        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? filename : ns.deletingPathExtension
        return (base, ext)
    }

    /// 文件版：`a.zip` → `a 2.zip`，`backup.tar.gz` → `backup 2.tar.gz`
    static func file(_ url: URL) -> URL {
        guard fileExists(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let (base, ext) = splitNameAndExtension(url.lastPathComponent)
        for index in 2...(maxAttempts + 1) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fileExists(candidate) { return candidate }
        }
        let fallback = ext.isEmpty
            ? "\(base) \(UUID().uuidString.prefix(8))"
            : "\(base) \(UUID().uuidString.prefix(8)).\(ext)"
        return folder.appendingPathComponent(fallback)
    }

    private static func fileExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// 目录版：`a` → `a 2`。
    /// `reserved` 用于同一批多选：两个包都叫 a，不能都解到 a/
    static func directory(_ url: URL, avoiding reserved: Set<String> = []) -> URL {
        let parent = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        var candidate = url
        var index = 2
        while (fileExists(candidate) || reserved.contains(candidate.path))
                && index <= maxAttempts + 1 {
            candidate = parent.appendingPathComponent("\(base) \(index)", isDirectory: true)
            index += 1
        }
        if fileExists(candidate) || reserved.contains(candidate.path) {
            return parent.appendingPathComponent("\(base) \(UUID().uuidString.prefix(8))", isDirectory: true)
        }
        return candidate
    }
}
