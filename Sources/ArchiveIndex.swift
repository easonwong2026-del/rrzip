// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Foundation

/// 侧栏目录树节点（只包含目录）
struct FolderNode: Identifiable, Hashable {
    var optionalChildren: [FolderNode]? { children.isEmpty ? nil : children }
    let path: String        // 包内完整前缀，根为空串
    let name: String
    var children: [FolderNode]
    var id: String { path }
}

/// 列表排序：点表头切换，目录永远在前，组内按这一列排
enum SortKey: String, CaseIterable, Identifiable {
    case name, size, modified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .modified: return "修改时间"
        }
    }
}

@MainActor
final class ArchiveIndex {
    // MARK: - 派生数据缓存
    //
    // SwiftUI 每次求值 body 都会多次访问这些属性，10 万条目的包上原来的
    // O(n) 重算会把滚动和切目录拖垮。这里按 Frame 建一次索引，之后按前缀 O(1) 取。

    private struct FrameCache {
        let frameID: UUID
        /// 父目录前缀 → 该层的直接子项（已排序，目录在前）
        let childIndex: [String: [ArchiveEntry]]
        let tree: [FolderNode]
    }

    private var frameCache: FrameCache?
    /// 列表结果缓存。键里带 frame / 前缀 / 排序 / 关键词，
    /// 任何一项变了就重算——无搜索时也走缓存，否则每次重绘都要重排。
    private var listCache: (key: String, result: [ArchiveEntry])?
    private var revealIndexCache: (key: String, index: Int?)?

    private func cachedFrame(_ frame: ArchiveModel.Frame) -> FrameCache {
        if let cache = frameCache, cache.frameID == frame.id { return cache }
        let index = Self.buildChildIndex(frame.entries)
        let cache = FrameCache(
            frameID: frame.id,
            childIndex: index,
            tree: Self.buildTree(from: index)
        )
        frameCache = cache
        return cache
    }

    func invalidateOrder() { listCache = nil }
    func invalidateSelection() { revealIndexCache = nil }

    func entries(in frame: ArchiveModel.Frame, at prefix: String) -> [ArchiveEntry] {
        cachedFrame(frame).childIndex[prefix] ?? []
    }

    func folderTree(in frame: ArchiveModel.Frame) -> [FolderNode] {
        cachedFrame(frame).tree
    }

    func firstSelectedIndex(in frame: ArchiveModel.Frame, columns: Bool, entries: [ArchiveEntry],
                            selection: Set<ArchiveEntry.ID>) -> Int? {
        let key = columns ? "columns|\(frame.id)|\(frame.prefix)" : listCache?.key ?? ""
        if let cached = revealIndexCache, cached.key == key { return cached.index }
        let index = entries.firstIndex { selection.contains($0.id) }
        revealIndexCache = (key, index)
        return index
    }

    func displayEntries(for frame: ArchiveModel.Frame, searchText: String,
                        sortKey: SortKey, sortAscending: Bool) -> [ArchiveEntry] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(frame.id)|\(frame.prefix)|\(sortKey.rawValue)|\(sortAscending)|\(keyword)"
        if let cached = listCache, cached.key == key { return cached.result }

        let base = keyword.isEmpty
            ? (cachedFrame(frame).childIndex[frame.prefix] ?? [])
            : frame.entries.filter { $0.path.localizedCaseInsensitiveContains(keyword) }
        let result = Self.sortEntries(base, by: sortKey, ascending: sortAscending)
        listCache = (key, result)
        return result
    }

    /// 目录永远在前（跟访达一致），组内按当前列排
    nonisolated static func sortEntries(_ list: [ArchiveEntry], by sortKey: SortKey, ascending: Bool) -> [ArchiveEntry] {
        let dirs = list.filter(\.isDirectory).sorted(by: byName)
        let files = list.filter { !$0.isDirectory }.sorted {
            compare($0, $1, by: sortKey, ascending: ascending)
        }
        return dirs + files
    }

    nonisolated private static func byName(_ a: ArchiveEntry, _ b: ArchiveEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    nonisolated private static func compare(_ a: ArchiveEntry, _ b: ArchiveEntry,
                                           by sortKey: SortKey, ascending: Bool) -> Bool {
        switch sortKey {
        case .name:
            return ascending ? byName(a, b) : byName(b, a)
        case .size:
            if a.size != b.size { return ascending ? a.size < b.size : a.size > b.size }
        case .modified:
            switch (a.modifiedDate, b.modifiedDate) {
            case (let left?, let right?) where left != right:
                return ascending ? left < right : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        }
        return byName(a, b)
    }

    /// 一次遍历建立「父前缀 → 子项」索引；显式目录和路径里隐含的目录都会补齐
    nonisolated static func buildChildIndex(_ entries: [ArchiveEntry]) -> [String: [ArchiveEntry]] {
        var index: [String: [ArchiveEntry]] = [:]
        var dirs: [String: ArchiveEntry] = [:]

        func noteDirectory(_ dirPath: String, modified: String, modifiedDate: Date?) {
            guard !dirPath.isEmpty, dirs[dirPath] == nil else { return }
            dirs[dirPath] = ArchiveEntry(path: dirPath, size: 0, modified: modified, mode: "drwxr-xr-x",
                                         modifiedDate: modifiedDate)
            let trimmed = String(dirPath.dropLast())
            if let slash = trimmed.lastIndex(of: "/") {
                noteDirectory(String(trimmed[trimmed.startIndex...slash]), modified: modified, modifiedDate: modifiedDate)
            }
        }

        for entry in entries {
            if entry.isDirectory {
                let dir = entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
                noteDirectory(dir, modified: entry.modified, modifiedDate: entry.modifiedDate)
                dirs[dir] = ArchiveEntry(path: dir, size: 0, modified: entry.modified, mode: entry.mode,
                                         modifiedDate: entry.modifiedDate, symlinkTarget: entry.symlinkTarget)
            } else if let slash = entry.path.lastIndex(of: "/") {
                let parent = String(entry.path[entry.path.startIndex...slash])
                noteDirectory(parent, modified: entry.modified, modifiedDate: entry.modifiedDate)
                index[parent, default: []].append(entry)
            } else {
                index["", default: []].append(entry)
            }
        }

        for (dir, entry) in dirs {
            let trimmed = String(dir.dropLast())
            let parent: String
            if let slash = trimmed.lastIndex(of: "/") {
                parent = String(trimmed[trimmed.startIndex...slash])
            } else {
                parent = ""
            }
            index[parent, default: []].append(entry)
        }

        for key in index.keys {
            index[key]?.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        return index
    }

    /// 由子项索引反推目录树
    nonisolated static func buildTree(from index: [String: [ArchiveEntry]]) -> [FolderNode] {
        var childrenByParent: [String: Set<String>] = [:]
        for (parent, items) in index {
            for item in items where item.isDirectory {
                childrenByParent[parent, default: []].insert(item.name)
            }
        }
        func build(_ prefix: String) -> [FolderNode] {
            (childrenByParent[prefix] ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { name in
                    let path = prefix + name + "/"
                    return FolderNode(path: path, name: name, children: build(path))
                }
        }
        return build("")
    }

    /// 把扁平路径折叠成一层目录视图
    nonisolated static func children(of prefix: String, in entries: [ArchiveEntry]) -> [ArchiveEntry] {
        var seen = Set<String>()
        var result: [ArchiveEntry] = []
        for entry in entries {
            guard entry.path.hasPrefix(prefix), entry.path != prefix else { continue }
            let rest = String(entry.path.dropFirst(prefix.count))
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[rest.startIndex..<slash])
                let dirPath = prefix + name + "/"
                if seen.insert(dirPath).inserted {
                    result.append(ArchiveEntry(path: dirPath, size: 0, modified: entry.modified, mode: "drwxr-xr-x"))
                }
            } else if seen.insert(entry.path).inserted {
                result.append(entry)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

}

extension ArchiveModel {
    var visibleEntries: [ArchiveEntry] {
        guard let frame = current else { return [] }
        return entries(at: frame.prefix)
    }

    var folderTree: [FolderNode] {
        guard let frame = current else { return [] }
        return archiveIndex.folderTree(in: frame)
    }

    func entries(at prefix: String) -> [ArchiveEntry] {
        guard let frame = current else { return [] }
        return archiveIndex.entries(in: frame, at: prefix)
    }

    var displayEntries: [ArchiveEntry] {
        guard let frame = current else { return [] }
        return archiveIndex.displayEntries(for: frame, searchText: searchText,
                                           sortKey: sortKey, sortAscending: sortAscending)
    }

    func sortEntries(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        ArchiveIndex.sortEntries(entries, by: sortKey, ascending: sortAscending)
    }

    var firstSelectedIndex: Int? {
        guard !selection.isEmpty, let frame = current else { return nil }
        return archiveIndex.firstSelectedIndex(in: frame, columns: isShowingColumns,
                                               entries: selectionOrder, selection: selection)
    }

    nonisolated static func buildChildIndex(_ entries: [ArchiveEntry]) -> [String: [ArchiveEntry]] {
        ArchiveIndex.buildChildIndex(entries)
    }

    nonisolated static func buildTree(from index: [String: [ArchiveEntry]]) -> [FolderNode] {
        ArchiveIndex.buildTree(from: index)
    }

    nonisolated static func children(of prefix: String, in entries: [ArchiveEntry]) -> [ArchiveEntry] {
        ArchiveIndex.children(of: prefix, in: entries)
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 归档格式的展示名
    var archiveFormatName: String {
        guard let frame = current else { return "" }
        if let detection = frame.detection { return detection.displayName }
        let ext = frame.archive.pathExtension.uppercased()
        return ext.isEmpty ? "未知格式" : ext + " 归档"
    }

    /// 识别方式，显示在详情面板（内容识别 = 后缀不可靠）
    var detectionSourceText: String {
        guard let detection = current?.detection else { return "" }
        return detection.source == .magic ? "按内容识别" : "按后缀识别"
    }

    /// 全包条目数
    var totalEntryCount: Int { current?.entries.count ?? 0 }

    /// 归档本身的修改时间
    var archiveModifiedText: String {
        guard let frame = current, let date = frame.archiveModified else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy 年 M 月 d 日 HH:mm"
        return formatter.string(from: date)
    }

    /// 当前归档的大小，显示在状态栏
    var archiveSizeText: String {
        guard let frame = current, let size = frame.archiveSize else { return "" }
        return ByteFormatter.string(size)
    }

}
