// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum CreateFormat: String, CaseIterable, Identifiable {
    case zip, sevenZip, tar, tgz
    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7Z（压缩率更高）"
        case .tar: return "TAR（不压缩）"
        case .tgz: return "TAR.GZ"
        }
    }

    var ext: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tgz: return "tgz"
        }
    }

    var usesSevenZip: Bool { self == .sevenZip }
}

enum CreateVolume: String, CaseIterable, Identifiable {
    case none, m100, m700, g1, g4
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不分卷"
        case .m100: return "每卷 100 MB"
        case .m700: return "每卷 700 MB"
        case .g1: return "每卷 1 GB"
        case .g4: return "每卷 4 GB"
        }
    }

    var argument: String? {
        switch self {
        case .none: return nil
        case .m100: return "100m"
        case .m700: return "700m"
        case .g1: return "1g"
        case .g4: return "4g"
        }
    }
}

/// 侧栏目录树节点（只包含目录）
struct FolderNode: Identifiable, Hashable {
    var optionalChildren: [FolderNode]? { children.isEmpty ? nil : children }
    let path: String        // 包内完整前缀，根为空串
    let name: String
    var children: [FolderNode]
    var id: String { path }
}

/// 一次批量处理的请求（拖入多个文件、或菜单里多选）
struct BatchRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let mode: BatchRunner.Mode
}

/// 外观：跟随系统 / 强制浅色 / 强制深色
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ArchiveViewMode: String, CaseIterable, Identifiable {
    case list, icons, columns
    var id: String { rawValue }
    var title: String {
        switch self {
        case .list: return "列表"
        case .icons: return "图标"
        case .columns: return "分栏"
        }
    }
    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        }
    }
}

/// 主窗口的两种工作模式：简化模式只做「打开 → 看 → 解压」，完整模式是工作台。
/// 两种模式共用同一个 ArchiveModel，切换时目录层级、选中项、预览都不重置。
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case compact, full
    var id: String { rawValue }
    var title: String { self == .compact ? "简化模式" : "完整模式" }
    /// 工具栏按钮的图标：当前在简化模式，就给「展开」
    var toggleSymbol: String {
        self == .compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
    }
    var toggleHelp: String {
        self == .compact ? "展开为完整模式（⌃⌘M）" : "收起为简化模式（⌃⌘M）"
    }
}

/// 应用内拖拽使用的自定义类型：暂存区靠它拿到「包 + 包内路径」，不必先解压
let rrzipEntryType = UTType(exportedAs: "com.rrzip.entry")

/// 暂存区里的一条：记住它来自哪个包，才能跨层、跨包累积
struct StashItem: Identifiable, Hashable {
    let id = UUID()
    let archive: URL
    let path: String
    let size: Int64
    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }
    var displaySize: String { ByteFormatter.string(size) }
}

/// 首页「最近打开」的一条。非沙盒应用按路径记就够，失效时置灰提示。
struct RecentArchive: Identifiable, Codable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let openedAt: Date
    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

struct CreateOptions {
    var format: CreateFormat = .zip
    var password: String = ""
    var volume: CreateVolume = .none
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

/// 暂存区导出时的落盘方式：不同包里的同名文件不能互相覆盖
enum StashLayout: String, CaseIterable, Identifiable {
    /// 每个包一个子目录（默认，最不容易撞名）
    case perArchive
    /// 全部平铺，同名自动加序号
    case flat
    /// 保留包内目录结构
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perArchive: return "每个包一个文件夹"
        case .flat: return "全部平铺（同名自动改名）"
        case .original: return "保留包内目录结构"
        }
    }

    var detail: String {
        switch self {
        case .perArchive: return "目标/A.zip/…、目标/B.zip/…，互不干扰"
        case .flat: return "都放在同一层，重复的自动加「 2」「 3」"
        case .original: return "按包里的路径还原，可能和已有文件重名"
        }
    }
}

@MainActor
final class ArchiveModel: ObservableObject {

    struct Frame: Identifiable {
        let id = UUID()
        let archive: URL
        let entries: [ArchiveEntry]
        let engine: ArchiveEngine
        /// 打开时识别出的格式（后缀或魔数），用于详情面板与引擎选择
        var detection: FormatDetection?
        /// 是否是从外层包展开出来的临时副本：不能在这里编辑
        var isNested: Bool = false
        /// 打开时记下的大小与修改时间，避免每次渲染都读磁盘
        var archiveSize: Int64?
        var archiveModified: Date?
        /// 当前所在目录在包内的前缀，根目录是空串
        var prefix: String = ""
        /// 面包屑显示的名字：根是包名，进入子目录后是目录名
        var title: String {
            prefix.isEmpty
                ? archive.deletingPathExtension().lastPathComponent
                : (prefix.split(separator: "/").last.map(String.init) ?? prefix)
        }
    }

    @Published private(set) var trail: [Frame] = []
    @Published var selection: Set<ArchiveEntry.ID> = []
    @Published var searchText: String = ""
    @Published var viewMode: ArchiveViewMode = .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "rrzip.viewMode") }
    }
    /// 列表排序：点表头切换列，再点一次换方向
    @Published var sortKey: SortKey = .name {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: "rrzip.sortKey")
            searchCache = nil
        }
    }
    @Published var sortAscending = true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: "rrzip.sortAscending")
            searchCache = nil
        }
    }
    @Published var appearance: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "rrzip.appearance") }
    }
    /// 简化 / 完整模式。放在 model 里而不是视图里，切换模式不会重建状态机
    @Published var workspaceMode: WorkspaceMode = .compact {
        didSet { UserDefaults.standard.set(workspaceMode.rawValue, forKey: "rrzip.workspaceMode") }
    }
    /// 最近一次「手动」切模式的时刻。自适应布局在这之后 5 分钟内不抢控制权
    private(set) var modePinnedAt: Date = .distantPast
    var isCompactMode: Bool { workspaceMode == .compact }
    /// 每次重新点同一行就自增，强制预览刷新
    @Published private(set) var previewToken: Int = 0
    @Published private(set) var isLoading = false
    @Published var status: String = "拖入一个压缩包，或按 ⌘O 打开"
    @Published var errorMessage: String?
    @Published private(set) var unlocked: Set<String> = []
    /// 非空时弹出批量面板
    @Published var batchRequest: BatchRequest?

    /// 暂存区：跨层、跨包攒起来，最后一次性导出
    @Published private(set) var stash: [StashItem] = []
    @Published var isStashVisible = false
    /// 暂存导出的落盘方式
    @Published var stashLayout: StashLayout = .perArchive {
        didSet { UserDefaults.standard.set(stashLayout.rawValue, forKey: "rrzip.stashLayout") }
    }

    /// 首页「最近打开」，最多 8 条
    @Published private(set) var recentArchives: [RecentArchive] = []

    var current: Frame? { trail.last }
    /// 当前层是不是嵌套包里的临时副本
    var isNested: Bool { current?.isNested ?? false }
    var entries: [ArchiveEntry] { current?.entries ?? [] }
    var canGoBack: Bool { trail.count > 1 }

    // MARK: - 派生数据缓存
    //
    // SwiftUI 每次求值 body 都会多次访问这些属性，10 万条目的包上原来的
    // O(n) 重算会把滚动和切目录拖垮。这里按 Frame 建一次索引，之后按前缀 O(1) 取。

    private struct FrameCache {
        let frameID: UUID
        /// 父目录前缀 → 该层的直接子项（已排序，目录在前）
        let childIndex: [String: [ArchiveEntry]]
        let tree: [FolderNode]
        let builtAt: Date
    }

    private var frameCache: FrameCache?
    private var searchCache: (frameID: UUID, keyword: String, result: [ArchiveEntry])?

    private func cachedFrame() -> FrameCache? {
        guard let frame = current else { return nil }
        if let cache = frameCache, cache.frameID == frame.id { return cache }
        let index = Self.buildChildIndex(frame.entries)
        let cache = FrameCache(
            frameID: frame.id,
            childIndex: index,
            tree: Self.buildTree(from: index),
            builtAt: Date()
        )
        frameCache = cache
        return cache
    }

    /// 当前这一层要显示的条目（目录折叠成一行）
    var visibleEntries: [ArchiveEntry] {
        guard let frame = current, let cache = cachedFrame() else { return [] }
        return cache.childIndex[frame.prefix] ?? []
    }

    /// 侧栏目录树（与 childIndex 同源，不再单独扫一遍全包）
    var folderTree: [FolderNode] {
        cachedFrame()?.tree ?? []
    }

    /// 取任意前缀下的一层条目（分栏视图要同时显示多列）
    func entries(at prefix: String) -> [ArchiveEntry] {
        cachedFrame()?.childIndex[prefix] ?? []
    }

    /// 列表实际渲染的数据：搜索时是全包匹配结果，否则是当前层
    var displayEntries: [ArchiveEntry] {
        guard let frame = current else { return [] }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            return sortEntries(cachedFrame()?.childIndex[frame.prefix] ?? [])
        }
        if let cached = searchCache, cached.frameID == frame.id, cached.keyword == keyword {
            return cached.result
        }
        let result = sortEntries(frame.entries.filter {
            $0.path.localizedCaseInsensitiveContains(keyword)
        })
        searchCache = (frame.id, keyword, result)
        return result
    }

    /// 目录永远在前（跟访达一致），组内按当前列排
    func sortEntries(_ list: [ArchiveEntry]) -> [ArchiveEntry] {
        let dirs = list.filter(\.isDirectory).sorted(by: byName)
        let files = list.filter { !$0.isDirectory }.sorted(by: compare)
        return dirs + files
    }

    private func byName(_ a: ArchiveEntry, _ b: ArchiveEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private func compare(_ a: ArchiveEntry, _ b: ArchiveEntry) -> Bool {
        let ascending: Bool
        switch sortKey {
        case .name: ascending = byName(a, b)
        case .size: ascending = a.size < b.size
        case .modified: ascending = a.modified < b.modified
        }
        return sortAscending ? ascending : !ascending
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
    }

    /// 一次遍历建立「父前缀 → 子项」索引；显式目录和路径里隐含的目录都会补齐
    nonisolated static func buildChildIndex(_ entries: [ArchiveEntry]) -> [String: [ArchiveEntry]] {
        var index: [String: [ArchiveEntry]] = [:]
        var dirs: [String: ArchiveEntry] = [:]

        func noteDirectory(_ dirPath: String, modified: String) {
            guard !dirPath.isEmpty, dirs[dirPath] == nil else { return }
            dirs[dirPath] = ArchiveEntry(path: dirPath, size: 0, modified: modified, mode: "drwxr-xr-x")
            let trimmed = String(dirPath.dropLast())
            if let slash = trimmed.lastIndex(of: "/") {
                noteDirectory(String(trimmed[trimmed.startIndex...slash]), modified: modified)
            }
        }

        for entry in entries {
            if entry.isDirectory {
                let dir = entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
                noteDirectory(dir, modified: entry.modified)
            } else if let slash = entry.path.lastIndex(of: "/") {
                let parent = String(entry.path[entry.path.startIndex...slash])
                noteDirectory(parent, modified: entry.modified)
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

    /// 当前选中的第一个条目（键盘导航与快速查看用）
    var selectedEntry: ArchiveEntry? {
        let list = isSearching ? displayEntries : visibleEntries
        return list.first { selection.contains($0.id) }
    }

    /// 上下键移动选中
    func moveSelection(by delta: Int) {
        let list = isSearching ? displayEntries : visibleEntries
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex { selection.contains($0.id) }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + delta, 0), list.count - 1)
        } else {
            nextIndex = delta > 0 ? 0 : list.count - 1
        }
        let entry = list[nextIndex]
        selection = [entry.id]
    }

    /// 回车：目录进入下一层，嵌套包展开，文件走默认预览
    func activateSelected() {
        guard let entry = selectedEntry else { return }
        activate(entry)
    }

    /// 最近一次单击的锚点，⇧ 连选以它为起点
    private var selectionAnchor: String?

    /// 单击：选中并刷新预览
    func select(_ entry: ArchiveEntry) {
        select(entry, modifiers: [])
    }

    /// 带修饰键的选中：⌘ 反选、⇧ 连选，跟访达的习惯一致
    func select(_ entry: ArchiveEntry, modifiers: NSEvent.ModifierFlags) {
        let list = isSearching ? displayEntries : visibleEntries

        if modifiers.contains(.command) {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            selectionAnchor = entry.id
            previewToken &+= 1
            return
        }

        if modifiers.contains(.shift),
           let anchor = selectionAnchor,
           let from = list.firstIndex(where: { $0.id == anchor }),
           let to = list.firstIndex(where: { $0.id == entry.id }) {
            let range = from <= to ? from...to : to...from
            selection = Set(list[range].map(\.id))
            previewToken &+= 1
            return
        }

        if selection == [entry.id] {
            previewToken &+= 1      // 重复点同一条也要重新加载
        } else {
            selection = [entry.id]
        }
        selectionAnchor = entry.id
    }

    /// 双击：目录进入下一层，嵌套包展开，普通文件交给默认程序打开
    func activate(_ entry: ArchiveEntry) {
        if entry.isDirectory {
            pushFolder(entry)
        } else if entry.isArchive {
            enter(entry)
        } else {
            openEntry(entry)
        }
    }

    /// 双击 / 回车打开普通文件：先按需解到临时目录，再交给系统默认程序
    func openEntry(_ entry: ArchiveEntry) {
        payloadURL(for: entry) { url in
            guard let url else { return }
            NSWorkspace.shared.open(url)
            // 打开的是按需解出的临时副本，编辑不会写回包里，必须在状态栏说清楚
            self.status = "已打开 \(entry.name)：临时副本，修改不会写回压缩包"
        }
    }

    /// ⌘A：把当前这一层全选（搜索状态下选搜索结果）
    func selectAll() {
        let list = isSearching ? displayEntries : visibleEntries
        selection = Set(list.map(\.id))
        selectionAnchor = list.first?.id
        previewToken &+= 1
    }

    /// 侧栏跳转：从根重建目录栈
    func jump(to path: String) {
        guard let root = trail.first else { return }
        var stack = [root]
        var accumulated = ""
        for part in path.split(separator: "/").map(String.init) {
            accumulated += part + "/"
            stack.append(Frame(archive: root.archive, entries: root.entries,
                               engine: root.engine, detection: root.detection, prefix: accumulated))
        }
        trail = stack
        selection = []
    }

    private func pushFolder(_ entry: ArchiveEntry) {
        guard let frame = current else { return }
        var next = frame
        next = Frame(archive: frame.archive, entries: frame.entries, engine: frame.engine,
                     detection: frame.detection, prefix: entry.path)
        trail.append(next)
        selection = []
        status = "\(Self.children(of: entry.path, in: frame.entries).count) 个项目 · \(entry.name)"
    }
    var isEncrypted: Bool { current.map { unlocked.contains($0.archive.path) } ?? false }

    private var passwords: [String: String] = [:]

    init() {
        // 调试用：defaults write com.rrzip.mac rrzip.viewMode -string icons
        if let mode = UserDefaults.standard.string(forKey: "rrzip.viewMode"),
           let parsed = ArchiveViewMode(rawValue: mode) {
            viewMode = parsed
        }
        if let mode = UserDefaults.standard.string(forKey: "rrzip.appearance"),
           let parsed = AppearanceMode(rawValue: mode) {
            appearance = parsed
        }
        if let mode = UserDefaults.standard.string(forKey: "rrzip.workspaceMode"),
           let parsed = WorkspaceMode(rawValue: mode) {
            workspaceMode = parsed
        }
        if let layout = UserDefaults.standard.string(forKey: "rrzip.stashLayout"),
           let parsed = StashLayout(rawValue: layout) {
            stashLayout = parsed
        }
        if let key = UserDefaults.standard.string(forKey: "rrzip.sortKey"),
           let parsed = SortKey(rawValue: key) {
            sortKey = parsed
        }
        if UserDefaults.standard.object(forKey: "rrzip.sortAscending") != nil {
            sortAscending = UserDefaults.standard.bool(forKey: "rrzip.sortAscending")
        }
        if let keyword = UserDefaults.standard.string(forKey: "rrzip.search") {
            searchText = keyword
        }
        loadRecentArchives()
    }
    /// 预览/导出缓存：key = 归档路径 + 修改时间 + 条目路径
    private var payloadCache: [String: URL] = [:]

    // MARK: - 工作模式
    /// 用户主动展开 / 收起：记下时刻，冷却期内不再自动切换
    func toggleWorkspaceMode() {
        setWorkspaceMode(workspaceMode == .compact ? .full : .compact, manual: true)
    }

    func setWorkspaceMode(_ mode: WorkspaceMode, manual: Bool) {
        if manual { modePinnedAt = Date() }
        guard workspaceMode != mode else { return }
        workspaceMode = mode
    }

    /// 窗口宽度变化时该不该跟着换模式；nil = 不动。
    /// 手动切过之后 5 分钟内不抢控制权，避免「刚展开又被弹回去」。
    func autoMode(forWidth width: Double) -> WorkspaceMode? {
        guard Date().timeIntervalSince(modePinnedAt) > 300 else { return nil }
        if width < 760, workspaceMode == .full { return .compact }
        if width > 900, workspaceMode == .compact { return .full }
        return nil
    }

    // MARK: - 最近打开（首页）

    private static let recentKey = "rrzip.recentArchives"

    private func loadRecentArchives() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentKey),
              let list = try? JSONDecoder().decode([RecentArchive].self, from: data)
        else { return }
        recentArchives = list
    }

    /// 打开成功后记一笔；同一个包只保留最新一条
    func recordRecent(_ url: URL) {
        var list = recentArchives.filter { $0.path != url.path }
        list.insert(RecentArchive(path: url.path, name: url.lastPathComponent, openedAt: Date()), at: 0)
        recentArchives = Array(list.prefix(8))
        saveRecentArchives()
    }

    func removeRecent(_ item: RecentArchive) {
        recentArchives.removeAll { $0.path == item.path }
        saveRecentArchives()
    }

    func clearRecentArchives() {
        recentArchives = []
        saveRecentArchives()
    }

    private func saveRecentArchives() {
        guard let data = try? JSONEncoder().encode(recentArchives) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentKey)
    }

    // MARK: - 快速压缩（首页）

    /// 首页拖入：不弹选项，直接在同目录生成 ZIP。重名自动加序号。
    func quickCompress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let folder = urls[0].deletingLastPathComponent()
        let base: String
        if urls.count == 1 {
            let name = urls[0].deletingPathExtension().lastPathComponent
            base = name.isEmpty ? "归档" : name
        } else {
            let name = folder.lastPathComponent
            base = name.isEmpty ? "归档" : name
        }
        let output = Self.uniqueOutput(folder.appendingPathComponent(base)
            .appendingPathExtension("zip"))
        isLoading = true
        status = "正在压缩 \(urls.count) 项…"
        Task {
            do {
                let items = urls
                try await Task.detached(priority: .userInitiated) {
                    try Self.writeArchive(at: output, from: items, format: .zip,
                                           password: "", volume: nil)
                }.value
                isLoading = false
                status = "已生成 \(output.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                isLoading = false
                status = "压缩失败"
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 目标已存在时找下一个可用名字，绝不覆盖
    nonisolated static func uniqueOutput(_ url: URL) -> URL {
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

    // MARK: - 工作目录

    private lazy var workspace: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rrzip", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let scratch = base.appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)   // 上次运行留下的临时文件全部清掉
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return base
    }()

    private var scratch: URL { workspace.appendingPathComponent("scratch", isDirectory: true) }

    private func freshScratch(_ name: String = UUID().uuidString) -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 缓存与临时目录占用，设置页显示
    func cacheSizeOnDisk() -> Int64 {
        Self.directorySize(workspace)
    }

    /// 清掉缩略图、预览临时副本与解压缓存；不动任何压缩包
    func clearCaches() {
        ThumbnailStore.shared.clear()
        payloadCache.removeAll()
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        status = "缓存已清理"
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - 打开

    func open(url: URL) {
        // 统一走格式识别：后缀说不清时读魔数，改过名 / 没后缀的包也能打开。
        // 这里不能再按后缀前置拦截，否则拖入、⌘O、访达打开三条路径都和 README 的承诺不一致。
        switch OpenGate.decide(url) {
        case .open:
            loadFrame(url: url, resetTrail: true)
        case .unrecognized:
            errorMessage = "无法识别这个文件：\(url.lastPathComponent)\n后缀不认识，内容也不像已知的压缩包。"
        case .unsupported(let detection):
            errorMessage = "\(detection.displayName) 目前只能识别，打不开（本机引擎不支持）。"
        }
    }

    /// 右键准备：点中已选中的条目时保留整组选择（跟访达一致），点未选中的条目才改成单选
    func prepareContextSelection(_ entry: ArchiveEntry) {
        guard !selection.contains(entry.id) else { return }
        selection = [entry.id]
        selectionAnchor = entry.id
        previewToken &+= 1
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择一个压缩包；选多个会进入批量处理"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        if urls.count > 1 {
            batchRequest = BatchRequest(urls: urls, mode: .extract)
        } else if let url = urls.first {
            open(url: url)
        }
    }

    /// 菜单里的「批量处理…」
    func pickBatch() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择要批量处理的压缩包"
        panel.prompt = "下一步"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        batchRequest = BatchRequest(urls: panel.urls, mode: .extract)
    }

    /// 校验当前打开的包
    func verifyCurrent() {
        guard let frame = current else { return }
        let password = passwords[frame.archive.path]
        isLoading = true
        status = "正在校验 \(frame.archive.lastPathComponent)…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SevenZip.verify(frame.archive, password: password)
                }.value
                isLoading = false
                status = "校验通过 · \(frame.archive.lastPathComponent)"
            } catch {
                isLoading = false
                status = "校验失败"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadFrame(url: URL, resetTrail: Bool, restorePrefix: String? = nil) {
        isLoading = true
        status = "正在读取 \(url.lastPathComponent)…"
        Task { await performLoad(url: url, resetTrail: resetTrail, restorePrefix: restorePrefix) }
    }

    private func performLoad(url: URL, resetTrail: Bool, restorePrefix: String? = nil) async {
        var passphrase = passwords[url.path]
        let detection = FormatDetector.detect(url)
        // 磁盘映像类（dmg/vhd/qcow2…）libarchive 读不了，直接交给 7-Zip。
        // 起始引擎跟批量解压 / 暂存导出一样，都由 ArchiveService 决定。
        var engine: ArchiveEngine = ArchiveService.engineOrder(for: url).first ?? .libarchive
        var entries: [ArchiveEntry]?
        var askedPassword = false
        var switchedEngine = false

        for _ in 0..<4 {
            do {
                // 快照成常量再进并发闭包：Swift 6 不允许捕获可变变量
                let currentEngine = engine
                let currentPassphrase = passphrase
                let result: [ArchiveEntry] = try await Task.detached(priority: .userInitiated) {
                    switch currentEngine {
                    case .libarchive: return try Tar.list(url, passphrase: currentPassphrase)
                    case .sevenZip: return try SevenZip.list(url, password: currentPassphrase)
                    }
                }.value
                entries = result
                break
            } catch ArchiveError.needsPassword {
                if !askedPassword {
                    guard let typed = askPassword(for: url, wrong: false) else { return finishLocked() }
                    askedPassword = true
                    passphrase = typed
                    passwords[url.path] = typed
                    continue
                }
                if engine == .libarchive && !switchedEngine {
                    switchedEngine = true
                    engine = .sevenZip
                    continue
                }
                errorMessage = "密码不正确"
                return finishLocked()
            } catch let ArchiveError.tool(message) {
                let lower = message.lowercased()
                if lower.contains("header is encrypted"), engine == .libarchive, !switchedEngine {
                    switchedEngine = true
                    engine = .sevenZip
                    continue
                }
                if Tar.looksEncrypted(message), !askedPassword {
                    guard let typed = askPassword(for: url, wrong: false) else { return finishLocked() }
                    askedPassword = true
                    passphrase = typed
                    passwords[url.path] = typed
                    continue
                }
                isLoading = false
                status = "读取失败"
                errorMessage = message
                return
            } catch {
                isLoading = false
                status = "读取失败"
                errorMessage = error.localizedDescription
                return
            }
        }

        guard let entries else {
            isLoading = false
            status = "读取失败"
            return
        }

        if passphrase != nil { unlocked.insert(url.path) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let frame = Frame(
            archive: url, entries: entries, engine: engine, detection: detection,
            isNested: !resetTrail,
            archiveSize: attrs?[.size] as? Int64,
            archiveModified: attrs?[.modificationDate] as? Date
        )
        if resetTrail {
            trail = [frame]
            recordRecent(url)
        } else {
            trail.append(frame)
        }
        selection = []
        isLoading = false
        if let prefix = restorePrefix, !prefix.isEmpty {
            jump(to: prefix)          // 编辑后回到原来那一层
            status = "\(visibleEntries.count) 个项目 · \(url.lastPathComponent)"
        } else {
            status = "\(Self.children(of: "", in: entries).count) 个项目 · \(url.lastPathComponent)"
        }
    }

    // MARK: - 原地编辑

    /// 往当前归档里加文件（落在当前目录下）
    func addFiles() {
        guard let frame = current else { return }
        guard !frame.isNested else {
            errorMessage = "嵌套包里的内容来自外层包的临时副本，改动不会保存。\n请先把内层包导出，再单独打开编辑。"
            return
        }
        let panel = NSOpenPanel()
        panel.message = "选择要加入 \(frame.archive.lastPathComponent) 的文件"
        panel.prompt = "加入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let items = panel.urls
        let archive = frame.archive
        let prefix = frame.prefix

        // 同名文件会被 7-Zip 直接替换，先问一句
        let existing = Set(Self.children(of: prefix, in: frame.entries).map(\.name))
        let conflicts = items.filter { existing.contains($0.lastPathComponent) }
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = "有 \(conflicts.count) 个同名文件"
            alert.informativeText = "继续会覆盖压缩包里的同名文件：\n"
                + conflicts.prefix(5).map(\.lastPathComponent).joined(separator: "、")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "覆盖")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let password = passwords[archive.path]

        isLoading = true
        status = "正在加入 \(items.count) 项…"
        Task {
            do {
                let snapshotItems = items
                try await Task.detached(priority: .userInitiated) {
                    try SevenZip.add(archive, items: snapshotItems, prefix: prefix, password: password)
                }.value
                loadFrame(url: archive, resetTrail: true, restorePrefix: prefix)
            } catch {
                isLoading = false
                status = "加入失败"
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 删除选中的条目
    func deleteSelection() {
        guard let frame = current else { return }
        guard !frame.isNested else {
            errorMessage = "嵌套包里的内容来自外层包的临时副本，改动不会保存。\n请先把内层包导出，再单独打开编辑。"
            return
        }
        let targets = (isSearching ? displayEntries : visibleEntries).filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "从压缩包中删除 \(targets.count) 项？"
        alert.informativeText = "只改动 \(frame.archive.lastPathComponent)，原始文件不受影响。删除后无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let paths = targets.map(\.path)
        let archive = frame.archive
        let prefix = frame.prefix
        let password = passwords[archive.path]

        isLoading = true
        status = "正在删除 \(paths.count) 项…"
        Task {
            do {
                let snapshotPaths = paths
                try await Task.detached(priority: .userInitiated) {
                    try SevenZip.remove(archive, entries: snapshotPaths, password: password)
                }.value
                loadFrame(url: archive, resetTrail: true, restorePrefix: prefix)
            } catch {
                isLoading = false
                status = "删除失败"
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 暂存区

    /// 把当前选中项放进暂存区
    func addSelectionToStash() {
        guard let frame = current else { return }
        let items = (isSearching ? displayEntries : visibleEntries).filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        for entry in items where !entry.isDirectory {
            let item = StashItem(archive: frame.archive, path: entry.path, size: entry.size)
            if !stash.contains(where: { $0.archive == item.archive && $0.path == item.path }) {
                stash.append(item)
            }
        }
        isStashVisible = true
        status = "已加入暂存 · 共 \(stash.count) 项"
        selection = []
    }

    /// 拖拽加入：按包内路径登记，不需要先把文件解出来
    func addToStash(archive: URL, path: String, size: Int64) {
        guard !path.hasSuffix("/") else { return }
        if !stash.contains(where: { $0.archive == archive && $0.path == path }) {
            stash.append(StashItem(archive: archive, path: path, size: size))
        }
        isStashVisible = true
        status = "已加入暂存 · 共 \(stash.count) 项"
    }

    func removeFromStash(_ item: StashItem) {
        stash.removeAll { $0.id == item.id }
    }

    func clearStash() {
        stash.removeAll()
        isStashVisible = false
    }

    /// 把暂存项全部解压到用户选的目录。按 stashLayout 分目录，绝不覆盖已有文件
    func exportStash() {
        guard !stash.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.message = "把暂存的 \(stash.count) 个文件导出到"
        panel.prompt = "导出"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let items = stash
        let passwordMap = passwords
        let layout = stashLayout
        isLoading = true
        status = "正在导出 \(items.count) 项…"
        Task {
            var failed = 0
            for item in items {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        _ = try Self.exportStashItem(item, to: destination, layout: layout,
                                                     password: passwordMap[item.archive.path])
                    }.value
                } catch {
                    failed += 1
                }
            }
            isLoading = false
            status = failed == 0 ? "已导出 \(items.count) 项" : "导出完成，\(failed) 项失败"
            if failed == 0 { stash.removeAll(); isStashVisible = false }
        }
    }

    /// 单个暂存项的落盘：按布局决定目标目录，平铺时用临时目录过渡并去重
    nonisolated static func exportStashItem(_ item: StashItem, to destination: URL,
                                           layout: StashLayout, password: String?) throws -> URL {
        let fm = FileManager.default
        switch layout {
        case .perArchive:
            let folder = destination
                .appendingPathComponent(item.archive.deletingPathExtension().lastPathComponent,
                                        isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try ArchiveService.extract(item.archive, entries: [item.path], to: folder,
                                       password: password)
            return folder.appendingPathComponent(item.path)

        case .original:
            try ArchiveService.extract(item.archive, entries: [item.path], to: destination,
                                       password: password)
            return destination.appendingPathComponent(item.path)

        case .flat:
            // 先解到临时目录，再挑一个不撞名的地方放进去
            let staging = fm.temporaryDirectory
                .appendingPathComponent("rrzip-flat-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            try ArchiveService.extract(item.archive, entries: [item.path], to: staging,
                                       password: password)
            let produced = staging.appendingPathComponent(item.path)
            let target = uniqueOutput(destination.appendingPathComponent(produced.lastPathComponent))
            try fm.moveItem(at: produced, to: target)
            return target
        }
    }

    /// 把暂存项打包成一个新的 zip
    func compressStash() {
        guard !stash.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "暂存.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let output = panel.url else { return }

        let items = stash
        let passwordMap = passwords
        isLoading = true
        status = "正在打包 \(items.count) 项…"
        Task {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("rrzip-stash-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            var files: [URL] = []
            for item in items {
                let folder = staging.appendingPathComponent(item.archive.deletingPathExtension().lastPathComponent,
                                                           isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? await Task.detached(priority: .userInitiated) {
                    try ArchiveService.extract(item.archive, entries: [item.path],
                                               to: folder, password: passwordMap[item.archive.path])
                }.value
                var file = folder.appendingPathComponent(item.path)
                if FileManager.default.fileExists(atPath: file.path) {
                    // 同名时加包名前缀，避免互相覆盖
                    let ext = file.pathExtension
                    let base = file.deletingPathExtension().lastPathComponent
                    let renamed = folder.appendingPathComponent("\(base)-\(item.archive.deletingPathExtension().lastPathComponent)")
                        .appendingPathExtension(ext)
                    try? FileManager.default.moveItem(at: file, to: renamed)
                    file = renamed
                }
                files.append(file)
            }

            do {
                // 快照成常量：Swift 6 不允许并发闭包捕获可变变量
                let filesToArchive = files
                try await Task.detached(priority: .userInitiated) {
                    try Self.writeArchive(at: output, from: filesToArchive,
                                          format: .zip, password: "", volume: nil)
                }.value
                isLoading = false
                status = "已打包 \(files.count) 项 · \(output.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                isLoading = false
                status = "打包失败"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishLocked() {
        isLoading = false
        status = "已加密，未解锁"
    }

    private func askPassword(for archive: URL, wrong: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = wrong ? "密码不正确" : "该压缩包已加密"
        alert.informativeText = "\(archive.lastPathComponent)\n输入密码后即可浏览与解压。"
        alert.alertStyle = wrong ? .warning : .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "密码"
        alert.accessoryView = field

        alert.addButton(withTitle: "解锁")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    // MARK: - 嵌套浏览

    func enter(_ entry: ArchiveEntry) {
        guard entry.isArchive, let frame = current else { return }
        isLoading = true
        status = "正在展开 \(entry.name)…"
        let passphrase = passwords[frame.archive.path]
        let engine = frame.engine

        Task {
            do {
                let destination = try await Task.detached { [archive = frame.archive, path = entry.path, scratch = self.scratch] () -> URL in
                    let dir = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    switch engine {
                    case .libarchive:
                        try Tar.extract(archive, entries: [path], to: dir, passphrase: passphrase)
                    case .sevenZip:
                        try SevenZip.extract(archive, entries: [path], to: dir, password: passphrase)
                    }
                    let extracted = dir.appendingPathComponent(path)
                    guard FileManager.default.fileExists(atPath: extracted.path) else {
                        throw ArchiveError.tool("未能展开 \(path)")
                    }
                    return extracted
                }.value
                isLoading = false
                loadFrame(url: destination, resetTrail: false)
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
                status = "展开失败"
            }
        }
    }

    /// 返回上一级（⌘[ / ⌘↑）
    func goBack() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        selection = []
    }

    func popTo(_ index: Int) {
        guard index >= 0, index < trail.count else { return }
        trail = Array(trail.prefix(index + 1))
        selection = []
    }

    // MARK: - 解压

    /// 设置里选了固定目录就直接用；没选才弹面板
    private var fixedExtractDestination: URL? {
        let path = UserDefaults.standard.string(forKey: "rrzip.extractDestination") ?? ""
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func extractAll() {
        guard let frame = current else { return }
        let destination: URL
        if let fixed = fixedExtractDestination {
            destination = fixed
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "解压到此处"
            panel.message = "选择解压目标文件夹"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        extract(entries: [], from: frame, to: destination)
    }

    func extractSelection() {
        guard let frame = current else { return }
        let chosen = entries.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let destination: URL
        if let fixed = fixedExtractDestination {
            destination = fixed
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "解压到此处"
            panel.message = "解压选中的 \(chosen.count) 个项目"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        extract(entries: chosen.map(\.path), from: frame, to: destination)
    }

    private func extract(entries paths: [String], from frame: Frame, to destination: URL) {
        isLoading = true
        status = "正在解压…"
        Task {
            var passphrase = passwords[frame.archive.path]
            for attempt in 0..<2 {
                do {
                    let currentPassphrase = passphrase
                    try await Task.detached {
                        switch frame.engine {
                        case .libarchive:
                            try Tar.extract(frame.archive, entries: paths, to: destination, passphrase: currentPassphrase)
                        case .sevenZip:
                            try SevenZip.extract(frame.archive, entries: paths, to: destination, password: currentPassphrase)
                        }
                    }.value
                    status = "已解压到 \(destination.lastPathComponent)"
                    isLoading = false
                    // 设置里可以关掉「解压后在访达中显示」
                    if UserDefaults.standard.object(forKey: "rrzip.revealAfterExtract") as? Bool ?? true {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                    return
                } catch let ArchiveError.tool(message) where Tar.looksEncrypted(message) {
                    guard attempt == 0, let typed = askPassword(for: frame.archive, wrong: passphrase != nil) else {
                        errorMessage = "密码错误或已取消"
                        status = "解压失败"
                        isLoading = false
                        return
                    }
                    passphrase = typed
                    passwords[frame.archive.path] = typed
                } catch {
                    errorMessage = error.localizedDescription
                    status = "解压失败"
                    isLoading = false
                    return
                }
            }
        }
    }

    /// 拖拽导出 / 预览用的临时文件（带缓存，同一份文件不重复解压）
    func payloadURL(for entry: ArchiveEntry, completion: @escaping (URL?) -> Void) {
        guard let frame = current else { return completion(nil) }

        let key = cacheKey(entry, in: frame)
        if let cached = payloadCache[key], FileManager.default.fileExists(atPath: cached.path) {
            return completion(cached)
        }

        let destination = freshScratch()
        let passphrase = passwords[frame.archive.path]
        let engine = frame.engine
        Task {
            let url = try? await Task.detached { () -> URL in
                switch engine {
                case .libarchive:
                    try Tar.extract(frame.archive, entries: [entry.path], to: destination, passphrase: passphrase)
                case .sevenZip:
                    try SevenZip.extract(frame.archive, entries: [entry.path], to: destination, password: passphrase)
                }
                let file = destination.appendingPathComponent(entry.path)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw ArchiveError.tool("导出失败")
                }
                return file
            }.value
            if let url {
                if payloadCache.count > 300 {
                    // 只清字典会把解压出来的文件留在磁盘上，一并删掉
                    for (_, cached) in payloadCache {
                        try? FileManager.default.removeItem(at: cached.deletingLastPathComponent())
                    }
                    payloadCache.removeAll()
                }
                payloadCache[key] = url
            }
            completion(url)
        }
    }

    private func cacheKey(_ entry: ArchiveEntry, in frame: Frame) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: frame.archive.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(frame.archive.path)|\(mtime)|\(entry.path)"
    }

    // MARK: - 创建

    /// 原子写入：先在同目录写隐藏临时文件，成功后再替换目标。
    /// 覆盖同名包时不会先删旧文件，失败也能保留原来的包。
    nonisolated static func writeArchive(
        at output: URL,
        from items: [URL],
        format: CreateFormat,
        password: String,
        volume: String?
    ) throws {
        let fm = FileManager.default
        let folder = output.deletingLastPathComponent()
        let base = output.deletingPathExtension().lastPathComponent
        let staged = folder
            .appendingPathComponent(".\(base)-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(output.pathExtension)

        func cleanupStaged() {
            try? fm.removeItem(at: staged)
            if let siblings = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for sibling in siblings where sibling.lastPathComponent.hasPrefix(staged.lastPathComponent + ".") {
                    try? fm.removeItem(at: sibling)
                }
            }
        }

        let needsSevenZip = format.usesSevenZip || !password.isEmpty || volume != nil
        do {
            if needsSevenZip {
                guard SevenZip.isAvailable else { throw ArchiveError.engineUnavailable }
                try SevenZip.create(
                    at: staged, from: items,
                    format: format == .sevenZip ? "7z" : format.ext,
                    password: password.isEmpty ? nil : password,
                    volume: volume
                )
            } else {
                try Tar.create(at: staged, from: items, format: format.ext)
            }
            try commitStaged(staged, to: output, hasVolumes: volume != nil)
        } catch {
            cleanupStaged()
            throw error
        }
    }

    /// 把临时产物换成目标名。有分卷时按前缀整组替换。
    nonisolated static func commitStaged(_ staged: URL, to output: URL, hasVolumes: Bool) throws {
        let fm = FileManager.default
        let folder = output.deletingLastPathComponent()
        let stagedName = staged.lastPathComponent
        let outName = output.lastPathComponent

        if hasVolumes {
            if let siblings = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for sibling in siblings where sibling.lastPathComponent.hasPrefix(outName + ".") {
                    try? fm.removeItem(at: sibling)
                }
            }
            if let siblings = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for sibling in siblings where sibling.lastPathComponent.hasPrefix(stagedName + ".") {
                    let suffix = sibling.lastPathComponent.dropFirst(stagedName.count)
                    try fm.moveItem(at: sibling, to: folder.appendingPathComponent(outName + suffix))
                }
            }
            if fm.fileExists(atPath: staged.path) {
                try fm.moveItem(at: staged, to: output)
            }
        } else if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: output)
        }
    }

    func createArchive() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.message = "选择要打包的文件或文件夹"
        picker.prompt = "下一步"
        guard picker.runModal() == .OK, !picker.urls.isEmpty else { return }
        let items = picker.urls

        guard let options = askCreateOptions(itemCount: items.count) else { return }

        let save = NSSavePanel()
        save.message = "保存压缩包"
        save.nameFieldStringValue = defaultName(for: items, format: options.format)
        guard save.runModal() == .OK, let picked = save.url else { return }
        var target = picked
        if target.pathExtension.lowercased() != options.format.ext {
            target = target.deletingPathExtension().appendingPathExtension(options.format.ext)
        }
        let output = target

        isLoading = true
        status = "正在压缩…"
        let volume = options.volume.argument

        Task {
            do {
                try await Task.detached {
                    // 先写临时文件，成功后才替换同名旧包：失败时原文件不动
                    try Self.writeArchive(
                        at: output, from: items, format: options.format,
                        password: options.password, volume: volume
                    )
                }.value
                status = "已创建 \(output.lastPathComponent)"
                isLoading = false
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                errorMessage = error.localizedDescription
                status = "创建失败"
                isLoading = false
            }
        }
    }

    private func defaultName(for items: [URL], format: CreateFormat) -> String {
        let base = items.count == 1
            ? items[0].deletingPathExtension().lastPathComponent
            : "归档"
        return "\(base).\(format.ext)"
    }

    private func askCreateOptions(itemCount: Int) -> CreateOptions? {
        let alert = NSAlert()
        alert.messageText = "压缩选项"
        alert.informativeText = "共 \(itemCount) 个项目"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 116))

        let formatLabel = NSTextField(labelWithString: "格式")
        formatLabel.frame = NSRect(x: 0, y: 88, width: 60, height: 18)
        let formatPopup = NSPopUpButton(frame: NSRect(x: 68, y: 83, width: 268, height: 26))
        formatPopup.addItems(withTitles: CreateFormat.allCases.map(\.title))
        // 设置里选的默认格式
        let preferred = UserDefaults.standard.string(forKey: "rrzip.defaultCreateFormat")
            .flatMap(CreateFormat.init(rawValue:)) ?? .zip
        formatPopup.selectItem(at: CreateFormat.allCases.firstIndex(of: preferred) ?? 0)

        let passwordLabel = NSTextField(labelWithString: "密码")
        passwordLabel.frame = NSRect(x: 0, y: 54, width: 60, height: 18)
        let passwordField = NSSecureTextField(frame: NSRect(x: 68, y: 49, width: 268, height: 24))
        passwordField.placeholderString = "留空则不加密"

        let volumeLabel = NSTextField(labelWithString: "分卷")
        volumeLabel.frame = NSRect(x: 0, y: 20, width: 60, height: 18)
        let volumePopup = NSPopUpButton(frame: NSRect(x: 68, y: 15, width: 170, height: 26))
        volumePopup.addItems(withTitles: CreateVolume.allCases.map(\.title))

        for label in [formatLabel, passwordLabel, volumeLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            container.addSubview(label)
        }
        container.addSubview(formatPopup)
        container.addSubview(passwordField)
        container.addSubview(volumePopup)

        alert.accessoryView = container
        alert.addButton(withTitle: "下一步")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = formatPopup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        var options = CreateOptions()
        options.format = CreateFormat.allCases[max(0, formatPopup.indexOfSelectedItem)]
        options.password = passwordField.stringValue
        options.volume = CreateVolume.allCases[max(0, volumePopup.indexOfSelectedItem)]

        if options.format == .tar || options.format == .tgz {
            options.password = ""
            options.volume = .none
        }
        return options
    }

    func revealInFinder() {
        guard let frame = current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([frame.archive])
    }

    func lockCurrent() {
        guard let frame = current else { return }
        passwords[frame.archive.path] = nil
        unlocked.remove(frame.archive.path)
        // 只清密码、保留已加载的条目列表，避免立刻又弹出密码框
        status = "已锁定 · \(frame.entries.count) 个项目"
    }
}
