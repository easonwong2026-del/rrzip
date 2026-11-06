// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  MenuBuilder.swift
//  ArchiveFinder
//
//  访达右键菜单的判定层。只回答两个问题：这次选择该出现哪几项、每项叫什么名字。
//  不写文件、不起进程、不碰 AppKit，好让全部分支都能在单元测试里跑到。
//
//  判定依据一律走 OpenGate，和主程序、快速查看、命令行同一套格式识别。
//

import Foundation

// FinderAction 定义在 Sources/FinderSettings.swift——主程序设置页也要用它，
// 放在这里会让扩展和主程序各有一份，迟早对不上。

/// 一次选择分类的结果。压缩包 / 普通项目 / 认得出但打不开，三类分开存。
struct FinderSelection {
    var archives: [URL] = []
    var plain: [URL] = []
    var unsupported: [URL] = []

    var total: Int { archives.count + plain.count }
    var isEmpty: Bool { archives.isEmpty && plain.isEmpty }

    /// 分类。默认最多对 20 个「后缀说不清」的项目读魔数——
    /// 右键选中几百个 txt 时不应该为了识别把每个文件的头部都读一遍。
    static func inspect(_ urls: [URL], magicBudget: Int = 20) -> FinderSelection {
        var result = FinderSelection()
        var budget = magicBudget

        for url in urls {
            if isDirectory(url) {
                result.plain.append(url)
                continue
            }
            // 后缀认得就不用读文件，OpenGate 内部也是这个顺序
            let suffixKnown = FormatDetector.detectByExtension(url) != nil
            if !suffixKnown {
                guard budget > 0 else {
                    result.plain.append(url)
                    continue
                }
                budget -= 1
            }
            switch OpenGate.decide(url) {
            case .open:
                result.archives.append(url)
            case .unsupported:
                result.unsupported.append(url)
            case .unrecognized:
                result.plain.append(url)
            }
        }
        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

enum FinderMenuBuilder {

    /// 选择 → 该出现的动作，顺序固定（解压在前，压缩在后）。
    /// 单个普通文件不出现「分别压缩」——那个动作只在多选时才有意义。
    static func actions(for selection: FinderSelection) -> [FinderAction] {
        let hasArchive = !selection.archives.isEmpty
        let hasPlain = !selection.plain.isEmpty

        switch (hasArchive, hasPlain) {
        case (true, false):
            return [.open, .extractHere, .extractToFolder]
        case (true, true):
            return selection.plain.count > 1
                ? [.extractHere, .compressZip, .compressEach]
                : [.extractHere, .compressZip]
        case (false, true):
            return selection.plain.count > 1
                ? [.compressZip, .compressSevenZip, .compressEach]
                : [.compressZip, .compressSevenZip]
        case (false, false):
            return []
        }
    }

    static func actions(for urls: [URL]) -> [FinderAction] {
        actions(for: FinderSelection.inspect(urls))
    }

    /// 菜单标题。带数量是刻意的：让用户一眼看出系统识别对了几个。
    static func title(for action: FinderAction, in selection: FinderSelection) -> String {
        let archiveCount = selection.archives.count
        let plainCount = selection.plain.count
        let itemCount = selection.total

        switch action {
        case .open:
            return archiveCount > 1 ? "用 rrzip 打开第一个" : "用 rrzip 打开"
        case .extractHere:
            return archiveCount > 1 ? "解压 \(archiveCount) 个压缩包到此处" : "解压到此处"
        case .extractToFolder:
            if archiveCount > 1 { return "分别解压到同名文件夹" }
            let name = truncatedBaseName(selection.archives.first)
            return name.isEmpty ? "解压到同名文件夹" : "解压到「\(name)」"
        case .compressZip:
            return itemCount > 1 ? "压缩 \(itemCount) 个项目为 ZIP" : "压缩为 ZIP"
        case .compressSevenZip:
            return itemCount > 1 ? "压缩 \(itemCount) 个项目为 7Z" : "压缩为 7Z"
        case .compressEach:
            return plainCount > 1 ? "分别压缩（\(plainCount) 个）" : "分别压缩"
        }
    }

    /// 认得出格式但本机打不开时的说明，没有就返回 nil
    static func unsupportedNote(for selection: FinderSelection) -> String? {
        guard let first = selection.unsupported.first else { return nil }
        let name = first.lastPathComponent
        if selection.unsupported.count > 1 {
            return "\(name) 等 \(selection.unsupported.count) 个格式暂不支持"
        }
        return "\(name) 暂不支持"
    }

    /// 包名过长会把菜单撑宽，超过 18 个字符截断
    private static func truncatedBaseName(_ url: URL?) -> String {
        guard let url else { return "" }
        let name = url.deletingPathExtension().lastPathComponent
        return name.count > 18 ? String(name.prefix(18)) + "…" : name
    }
}
