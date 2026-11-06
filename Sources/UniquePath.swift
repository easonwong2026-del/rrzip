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

import Foundation

enum UniquePath {

    /// 文件版：`a.zip` → `a 2.zip`
    static func file(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(index)")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// 目录版：`a` → `a 2`。
    /// `reserved` 用于同一批多选：两个包都叫 a，不能都解到 a/
    static func directory(_ url: URL, avoiding reserved: Set<String> = []) -> URL {
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
}
