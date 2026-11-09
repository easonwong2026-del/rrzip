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

/// 压缩级别。7zz 的 -mx 取值，数字越大越慢越小
enum CompressLevel: String, CaseIterable, Identifiable {
    case store, fast, normal, max
    var id: String { rawValue }

    var title: String {
        switch self {
        case .store: return "存储（不压缩）"
        case .fast: return "快速"
        case .normal: return "标准（推荐）"
        case .max: return "极限"
        }
    }

    var argument: Int {
        switch self {
        case .store: return 0
        case .fast: return 1
        case .normal: return 5
        case .max: return 9
        }
    }
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

/// 一次暂存导出的结果
struct StashExport {
    let url: URL
    /// 目标已有同名文件，按「不覆盖」跳过了
    let skipped: Bool
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

/// 选完文件、等 sheet 确认参数的那一批
struct PendingCreate: Identifiable {
    let id = UUID()
    let items: [URL]
}

struct CreateOptions {
    var format: CreateFormat = .zip
    var password: String = ""
    var volume: CreateVolume = .none
    var level: CompressLevel = .normal
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
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            // 关键词一变，列表内容整批换掉：留着已经看不见的选中项，
            // 预览是空的、底部却写「已选 N 项」，删除还会作用到不可见的条目
            pruneSelectionToDisplayed()
        }
    }
    /// 键盘导航计数。视图只在它变化时才把选中行滚进视口；
    /// 单击 / ⌘ 多选 / ⇧ 连选 / ⌘A 一律不动滚动位置。
    @Published private(set) var keyboardScrollTick: Int = 0
    /// 布局切换计数（视图形态 / 简化模式）。视图换了主体就重建了，
    /// 新滚动容器的「首次同步」不能当作滚动信号，得等布局落地后再补一次定位。
    @Published private(set) var layoutTick: Int = 0
    @Published var viewMode: ArchiveViewMode = .list {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "rrzip.viewMode")
            if viewMode != oldValue { layoutTick &+= 1 }
        }
    }
    /// 列表排序：点表头切换列，再点一次换方向
    @Published var sortKey: SortKey = .name {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: "rrzip.sortKey")
            listCache = nil
        }
    }
    @Published var sortAscending = true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: "rrzip.sortAscending")
            listCache = nil
        }
    }
    @Published var appearance: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "rrzip.appearance") }
    }
    /// 简化 / 完整模式。放在 model 里而不是视图里，切换模式不会重建状态机
    @Published var workspaceMode: WorkspaceMode = .compact {
        didSet {
            UserDefaults.standard.set(workspaceMode.rawValue, forKey: "rrzip.workspaceMode")
            if workspaceMode != oldValue { layoutTick &+= 1 }
        }
    }
    /// 最近一次「手动」切模式的时刻。自适应布局在这之后 5 分钟内不抢控制权
    private(set) var modePinnedAt: Date = .distantPast
    var isCompactMode: Bool { workspaceMode == .compact }
    /// 每次重新点同一行就自增，强制预览刷新
    @Published private(set) var previewToken: Int = 0
    @Published private(set) var isLoading = false
    @Published var status: String = "拖入一个压缩包，或按 ⌘O 打开"
    @Published var errorMessage: String?
    /// 一次性浮条提示：不打断操作，3 秒后自动消失。
    /// 用于「另有 N 个压缩包未打开」这类需要告知但不需要弹窗的情况。
    @Published var notice: String?
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
    }

    private var frameCache: FrameCache?
    /// 列表结果缓存。键里带 frame / 前缀 / 排序 / 关键词，
    /// 任何一项变了就重算——无搜索时也走缓存，否则每次重绘都要重排。
    private var listCache: (key: String, result: [ArchiveEntry])?

    private func cachedFrame() -> FrameCache? {
        guard let frame = current else { return nil }
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
        let key = "\(frame.id)|\(frame.prefix)|\(sortKey.rawValue)|\(sortAscending)|\(keyword)"
        if let cached = listCache, cached.key == key { return cached.result }

        let base = keyword.isEmpty
            ? (cachedFrame()?.childIndex[frame.prefix] ?? [])
            : frame.entries.filter { $0.path.localizedCaseInsensitiveContains(keyword) }
        let result = sortEntries(base)
        listCache = (key, result)
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

    /// 分栏视图当前是否真的在显示（它会退回列表：简化模式、搜索中都走列表）
    var isShowingColumns: Bool {
        !isCompactMode && viewMode == .columns && !isSearching
    }

    /// 命中顺序：单击 / ⌘ / ⇧ / 方向键都按**屏幕上看到的顺序**算。
    ///
    /// 列表与图标网格都渲染 `displayEntries`（受排序设置影响）；
    /// 分栏视图渲染的是 `entries(at:)`——那条路径恒为「目录在前、名称正序」，
    /// 不跟随排序设置。所以分栏里必须换用它自己那一份，否则按大小或倒序排过
    /// 再切分栏，方向键和 ⇧ 连选会跳到屏幕上不相邻的行。
    var selectionOrder: [ArchiveEntry] {
        if isShowingColumns, let frame = current {
            return entries(at: frame.prefix)
        }
        return displayEntries
    }

    /// 当前选中的条目：优先最近一次点中 / 键盘走到的那条，
    /// 它才是预览、快速查看、右键菜单真正对得上的对象。
    /// 只取 `selection` 里的任意一条时，⌘ 多选后预览会跳到另一行上去。
    var selectedEntry: ArchiveEntry? {
        let list = selectionOrder
        if let focusedID, selection.contains(focusedID),
           let entry = list.first(where: { $0.id == focusedID }) {
            return entry
        }
        return list.first { selection.contains($0.id) }
    }

    /// 上下键移动选中。`columns > 1` 时按「一行 columns 个」跳，图标网格用；
    /// 列表与分栏传默认值 1，三种视图共用同一套命中与锚点逻辑。
    func moveSelection(by delta: Int, columns: Int = 1) {
        let list = selectionOrder
        guard !list.isEmpty else { return }
        let step = max(1, columns)
        // 从锚点接着走：多选状态下不能每次从「第一条选中的」重新起算，
        // 否则 ⌘ 多选后按方向键会跳回列表顶部附近
        let basis = selectionAnchor.flatMap { anchor in list.firstIndex { $0.id == anchor } }
            ?? list.firstIndex { selection.contains($0.id) }
        let nextIndex: Int
        if let basis {
            let raw = basis + delta * step
            if raw < 0, step > 1, basis >= step {
                // 网格里往上越界：回到第一行的同一列，而不是被夹到第 0 格
                nextIndex = basis % step
            } else {
                nextIndex = min(max(raw, 0), list.count - 1)
            }
        } else {
            nextIndex = delta > 0 ? 0 : list.count - 1
        }
        let entry = list[nextIndex]
        selection = [entry.id]
        selectionAnchor = entry.id
        focusedID = entry.id
        keyboardScrollTick &+= 1
    }

    /// 回车：目录进入下一层，嵌套包展开，文件走默认预览
    func activateSelected() {
        guard let entry = selectedEntry else { return }
        activate(entry)
    }

    /// 最近一次单击的锚点，⇧ 连选以它为起点
    private var selectionAnchor: String?
    /// 最近一次真正点中 / 键盘走到的那条，决定预览显示谁
    private var focusedID: String?

    /// 列表内容变了（换关键词）之后，把已经不存在的选中项摘掉
    private func pruneSelectionToDisplayed() {
        guard !selection.isEmpty else { return }
        let displayed = Set(displayEntries.map(\.id))
        let kept = selection.intersection(displayed)
        guard kept != selection else { return }
        selection = kept
        if let focusedID, !kept.contains(focusedID) {
            self.focusedID = kept.first
        }
        if let selectionAnchor, !kept.contains(selectionAnchor) {
            self.selectionAnchor = kept.first
        }
    }

    /// 单击：选中并刷新预览
    func select(_ entry: ArchiveEntry) {
        select(entry, modifiers: [])
    }

    /// 带修饰键的选中：⌘ 反选、⇧ 连选，跟访达的习惯一致
    func select(_ entry: ArchiveEntry, modifiers: NSEvent.ModifierFlags) {
        let list = selectionOrder

        if modifiers.contains(.command) {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            selectionAnchor = entry.id
            focusedID = entry.id
            previewToken &+= 1
            return
        }

        if modifiers.contains(.shift),
           let anchor = selectionAnchor,
           let from = list.firstIndex(where: { $0.id == anchor }),
           let to = list.firstIndex(where: { $0.id == entry.id }) {
            let range = from <= to ? from...to : to...from
            selection = Set(list[range].map(\.id))
            // 连选的锚点保持不动（再按住 ⇧ 点别处还能继续延伸），
            // 但「当前这一条」是刚点的那行——预览要跟着它
            focusedID = entry.id
            previewToken &+= 1
            return
        }

        if selection == [entry.id] {
            previewToken &+= 1      // 重复点同一条也要重新加载
        } else {
            selection = [entry.id]
        }
        selectionAnchor = entry.id
        focusedID = entry.id
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
        let list = selectionOrder
        selection = Set(list.map(\.id))
        selectionAnchor = list.first?.id
        focusedID = list.first?.id
        previewToken &+= 1
    }

    /// 侧栏跳转：从根重建目录栈
    func jump(to path: String) {
        guard let root = trail.first else { return }
        var stack = [root]
        var accumulated = ""
        for part in path.split(separator: "/").map(String.init) {
            accumulated += part + "/"
            // 归档大小与修改时间要一起带下去：缩略图缓存键靠它们区分同名包，
            // 子目录帧丢了这两个值，换包后缩略图就会串图
            stack.append(Frame(archive: root.archive, entries: root.entries,
                               engine: root.engine, detection: root.detection,
                               archiveSize: root.archiveSize,
                               archiveModified: root.archiveModified,
                               prefix: accumulated))
        }
        trail = stack
        selection = []
    }

    private func pushFolder(_ entry: ArchiveEntry) {
        guard let frame = current else { return }
        let next = Frame(archive: frame.archive, entries: frame.entries, engine: frame.engine,
                         detection: frame.detection,
                         archiveSize: frame.archiveSize,
                         archiveModified: frame.archiveModified,
                         prefix: entry.path)
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
        // 旧版本在这里恢复上次的关键词，可它从来没被写过；真写进去反而更糟：
        // 启动时先带着一个关键词，第一个包打开就被筛成空列表。顺手清掉遗留键。
        UserDefaults.standard.removeObject(forKey: "rrzip.search")
        loadRecentArchives()
    }
    /// 预览/导出缓存：key = 归档路径 + 修改时间 + 条目路径
    private var payloadCache: [String: URL] = [:]
    /// 同一 key 正在解压：后来的调用者登记在这里，共享同一次结果
    private var payloadWaiters: [String: [(URL?) -> Void]] = [:]

    /// 临时副本的磁盘软预算。单个文件本身超预算时也照样解压，
    /// 只是它得等自己不再被占用、且比别的都老才会被回收。
    static let payloadDiskBudget: Int64 = 1024 * 1024 * 1024

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

    /// 设置页里选工作模式，等于用户手动切换。
    ///
    /// 设置页曾经直接绑 `$model.workspaceMode`：值改了、界面也切换了，
    /// 但 `modePinnedAt` 没更新，冷却期不生效——用户刚在设置里选完完整模式，
    /// 随便拖一下窗口就被自动模式抢回去，看起来像「设置不管用」。
    func selectWorkspaceModeFromSettings(_ mode: WorkspaceMode) {
        setWorkspaceMode(mode, manual: true)
    }

    /// 上一帧的窗口宽度，用来判断拖动方向
    private var lastAutoWidth: Double?

    /// 窗口宽度变化时该不该跟着换模式；nil = 不动。
    ///
    /// 判据是「方向 + 阈值」，不是滞回：同一个 818，往宽拉就展开、往窄拉就收起。
    /// 以前在收起和展开之间留 80pt 滞回，用户从 720 拉到 850 完全没反应，
    /// 体感就是「自动切换坏了」——这已经是第二次因为阈值被抱怨。
    ///
    /// 阈值来自 Layout（由三栏最小宽度推导），不写死。
    /// 手动切过之后 5 分钟内不抢控制权，避免「刚展开又被弹回去」。
    func autoMode(forWidth width: Double, now: Date = Date()) -> WorkspaceMode? {
        let previous = lastAutoWidth
        lastAutoWidth = width
        // 冷却期也要记宽度，否则 5 分钟后的第一帧方向是错的
        guard now.timeIntervalSince(modePinnedAt) > 300 else { return nil }
        // 第一帧没有方向信息，或宽度没变，不做判断
        guard let previous, previous != width else { return nil }

        let edge = Layout.autoCollapseWidth
        if workspaceMode == .compact, width >= edge, width > previous { return .full }
        if workspaceMode == .full, width < edge { return .compact }
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
    ///
    /// 走的是和「新建压缩包」同一条队列：前台正在解压时不会插队并行，
    /// 取消也只停自己这一条。`completion` 在任务真正有结局后才回调——
    /// 以前是发起压缩后立刻写「已生成 ZIP」，包还没影子就先报成功了。
    func quickCompress(_ urls: [URL], completion: (@MainActor (JobResult, URL) -> Void)? = nil) {
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
        // 落点等任务真正开始跑时再算：排队期间前一个同名任务可能已经把
        // 「A.zip」占了，提交时就算好会让第二个任务覆盖掉第一个的产物。
        let target = folder.appendingPathComponent(base).appendingPathExtension("zip")

        submitJob(title: "正在压缩", detail: target.lastPathComponent) { [weak self] jobID in
            guard let self else { return .cancelled }
            let output = Self.uniqueOutput(target)
            let result = await self.runArchiveJob(
                output: output, items: urls, format: .zip,
                password: "", volume: nil, level: CompressLevel.normal.argument,
                runningText: "正在压缩 \(urls.count) 项…", doneVerb: "已生成",
                jobID: jobID
            )
            completion?(result, output)
            return result
        }
    }

    /// 压缩任务的公共执行体：状态、写盘、完成后在访达里选中产物、取消与失败的落账。
    /// 新建面板和首页快速压缩只差几句文案，其余不该各写一遍——
    /// 上一次写两遍的结果就是一边漏传 jobID，取消按下去没反应。
    private func runArchiveJob(
        output: URL, items: [URL], format: CreateFormat,
        password: String, volume: String?, level: Int,
        runningText: String, doneVerb: String,
        jobID: UUID
    ) async -> JobResult {
        // 状态在真正开始执行时才写。入队时就写，会让状态栏提前显示
        // 「正在压缩」，而实际还在等前一个任务。
        status = runningText
        do {
            let onProgress: @Sendable (Double) -> Void = { [weak self] value in
                self?.reportProgress(value, for: jobID)
            }
            try await Task.detached {
                // 先写临时文件，成功后才替换同名旧包：失败时原文件不动
                try Self.writeArchive(
                    at: output, from: items, format: format,
                    password: password, volume: volume,
                    level: level, jobID: jobID, onProgress: onProgress
                )
            }.value
            if volume != nil {
                let parts = ArchiveModel.volumeFiles(of: output)
                status = "\(doneVerb) \(output.lastPathComponent).001（分 \(parts.count) 卷）"
                NSWorkspace.shared.activateFileViewerSelecting(Array(parts.prefix(1)))
            } else {
                status = "\(doneVerb) \(output.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
            return .succeeded
        } catch ArchiveError.cancelled {
            status = "已取消"
            // 临时产物由 writeArchive 自己清（staged 与它的分卷）。
            // 这里千万不能碰 output：用户可能选了一个已存在的同名包，
            // 在「取消」这个动作上删掉它，等于把旧文件毁了。
            return .cancelled
        } catch {
            errorMessage = error.localizedDescription
            status = "压缩失败"
            return .failed(error.localizedDescription)
        }
    }

    /// 目标已存在时找下一个可用名字，绝不覆盖（实现见 UniquePath）
    nonisolated static func uniqueOutput(_ url: URL) -> URL { UniquePath.file(url) }

    /// 目录版：不拼扩展名
    nonisolated static func uniqueDirectory(_ url: URL) -> URL { UniquePath.directory(url) }

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
        CacheMaintenance.size(of: workspace)
    }

    /// 清掉缩略图、预览临时副本与解压缓存；不动任何压缩包。
    /// 队列里有任务在跑、或还有排队的任务，就直接返回「忙」——
    /// 只判 `job != nil` 会漏掉排队中的任务：清完它一开始跑，要读的副本已经没了。
    @discardableResult
    func clearCaches() -> CacheCleanupReport {
        let report = CacheMaintenance.purge([workspace],
                                            busy: job != nil || !jobQueue.isEmpty)
        guard !report.blocked else { return report }

        ThumbnailStore.shared.clear()
        payloadCache.removeAll()
        // 目录本身留着：删掉再建会让正在进行的预览当场失败，也没这个必要
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        status = report.text
        return report
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
        // 嵌套包在 enter() 里挂过占用：从解压完成一直兜到它进 trail。
        // 这里所有出口（成功、读失败、等密码时被取消）都要放掉，否则那份临时
        // 目录永远占着、回收也动不了它。非嵌套包的路径上没有 hold，release 是空操作。
        defer { ScratchUsage.shared.release(url) }

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
                    guard let typed = await askPassword(for: url, wrong: false) else { return finishLocked() }
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
                    guard let typed = await askPassword(for: url, wrong: false) else { return finishLocked() }
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
        // 换包就是换浏览上下文：旧关键词留在输入框里，新包会被旧条件筛成
        // 「没有匹配的文件」，看起来像空包。打开另一个包、进嵌套包都按这个语义走。
        let switchedArchive = resetTrail || trail.last?.archive.path != url.path
        if switchedArchive { searchText = "" }
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

        // 这次打开如果是访达右键「解压」撞上加密包转过来的，解锁完就接着解
        if resetTrail {
            resumePendingExtractionIfNeeded(for: url)
        }
    }

    /// 访达那边点的「解压到此处 / 解压到包名」因为要密码没做完。
    /// 把包交过来只是手段，真正要做的事记在 PendingExtraction 里，这里收尾。
    private func resumePendingExtractionIfNeeded(for url: URL) {
        guard let pending = PendingExtraction.read(),
              pending.archives.contains(url.path) else { return }
        PendingExtraction.clear()

        // 太久以前的记录不动手：用户可能只是顺手打开了同名的另一个包
        guard Date().timeIntervalSince(pending.createdAt) < PendingExtraction.validInterval,
              let frame = current, frame.archive.path == url.path else { return }

        let destination: URL
        switch pending.mode {
        case .here:
            destination = url.deletingLastPathComponent()
        case .newFolder:
            let parent = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            destination = Self.uniqueDirectory(
                parent.appendingPathComponent(base.isEmpty ? "归档" : base, isDirectory: true))
        }
        status = "解压到 \(destination.lastPathComponent)…"
        extract(entries: [], from: frame, to: destination)
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
        let targets = selectionOrder.filter { selection.contains($0.id) }
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
        let items = selectionOrder.filter { selection.contains($0.id) }
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
        exportStash(to: destination)
    }

    /// 落点已定时的导出入口：面板走上面那个，测试直接调这个。
    /// 和压缩、暂存打包共用同一条队列，取消只停自己。
    func exportStash(to destination: URL) {
        guard !stash.isEmpty else { return }
        let items = stash
        let passwordMap = passwords
        let layout = stashLayout
        submitJob(title: "正在导出暂存", detail: "\(items.count) 项") { [weak self] jobID in
            guard let self else { return .cancelled }
            return await self.runStashExportJob(to: destination, items: items,
                                                passwords: passwordMap,
                                                layout: layout, jobID: jobID)
        }
    }

    private func runStashExportJob(to destination: URL, items: [StashItem],
                                   passwords passwordMap: [String: String],
                                   layout: StashLayout, jobID: UUID) async -> JobResult {
        var exported = 0
        /// 目标已存在、按「不覆盖」跳过的
        var skipped: [String] = []
        /// 真的失败了的，连原因一起记
        var failed: [String] = []

        do {
            for (index, item) in items.enumerated() {
                if TaskRegistry.wasCancelled(jobID) { throw ArchiveError.cancelled }
                status = "正在导出 \(index + 1)/\(items.count)…"
                do {
                    let outcome = try await Task.detached(priority: .userInitiated) {
                        try Self.exportStashItem(item, to: destination, layout: layout,
                                                 password: passwordMap[item.archive.path],
                                                 jobID: jobID)
                    }.value
                    if outcome.skipped { skipped.append(item.name) } else { exported += 1 }
                } catch ArchiveError.cancelled {
                    throw ArchiveError.cancelled
                } catch {
                    failed.append("\(item.name)：\(error.localizedDescription)")
                }
            }
        } catch ArchiveError.cancelled {
            // 和导出到一半的目录一样，这里只能如实说，不假装干净
            status = "已取消，目标目录可能留有部分已导出文件"
            return .cancelled
        } catch {
            status = "导出失败"
            return .failed(error.localizedDescription)
        }

        if !skipped.isEmpty {
            // 状态栏放不下长长的名单，浮条里说清楚哪些没导
            notice = "未覆盖已存在的文件：" + Self.previewList(skipped)
        }
        if !failed.isEmpty {
            status = exported > 0 ? "已导出 \(exported) 项 · \(failed.count) 项失败"
                                  : "导出失败"
            return .failed("这些没导出来：\n" + Self.previewList(failed, limit: 5))
        }

        status = skipped.isEmpty ? "已导出 \(exported) 项"
                                 : "已导出 \(exported) 项 · \(skipped.count) 项已存在，未覆盖"
        // 有跳过就留着暂存项：用户可能想换个目录再导一次
        if skipped.isEmpty { stash.removeAll(); isStashVisible = false }
        return .succeeded
    }

    /// 「a、b、c 等 N 项」——错误框和浮条共用
    nonisolated static func previewList(_ names: [String], limit: Int = 3) -> String {
        let head = names.prefix(limit).joined(separator: "、")
        return names.count > limit ? "\(head) 等 \(names.count) 项" : head
    }

    /// 把临时解出来的文件放进目标位置。目标已存在时不覆盖，返回 false。
    ///
    /// 用 move 而不是「先查再改名」：move 遇到同名目标自己就失败，
    /// 查完到落位之间被别人建了文件也不会盖掉——这正是「预检查之后才出现」
    /// 那条竞态的兜底，也是能稳定测到的那条路径。
    nonisolated static func installExport(_ produced: URL, to target: URL) throws -> Bool {
        let fm = FileManager.default
        do {
            try fm.moveItem(at: produced, to: target)
            return true
        } catch {
            if fm.fileExists(atPath: target.path) { return false }
            throw error
        }
    }

    /// 单个暂存项的落盘：按布局决定落点。
    /// 先解到目标同卷的隐藏目录，再 move 过去——同卷是改名，不额外拷一份；
    /// 取消或失败时目标目录里一个字节都不会出现，只留下待删的临时目录。
    nonisolated static func exportStashItem(_ item: StashItem, to destination: URL,
                                           layout: StashLayout, password: String?,
                                           jobID: UUID? = nil) throws -> StashExport {
        let fm = FileManager.default

        let target: URL
        switch layout {
        case .perArchive:
            target = destination
                .appendingPathComponent(item.archive.deletingPathExtension().lastPathComponent,
                                        isDirectory: true)
                .appendingPathComponent(item.path)
        case .original:
            target = destination.appendingPathComponent(item.path)
        case .flat:
            target = uniqueOutput(destination.appendingPathComponent(
                (item.path as NSString).lastPathComponent))
        }

        // 早跳过：已经存在就别为必被丢弃的文件白解一遍
        if fm.fileExists(atPath: target.path) { return StashExport(url: target, skipped: true) }

        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".rrzip-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try ArchiveService.extract(item.archive, entries: [item.path], to: staging,
                                   password: password, jobID: jobID)
        let produced = staging.appendingPathComponent(item.path)
        // 引擎返回 0 但文件不在（条目名对不上时会这样），不能算导出成功
        guard fm.fileExists(atPath: produced.path) else {
            throw ArchiveError.tool("「\(item.name)」没有解出来")
        }
        guard try installExport(produced, to: target) else {
            return StashExport(url: target, skipped: true)
        }
        return StashExport(url: target, skipped: false)
    }

    /// 把暂存项打包成一个新的 zip
    func compressStash() {
        guard !stash.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "暂存.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let output = panel.url else { return }
        packStash(to: output)
    }

    /// 落点已定时的打包入口：面板走上面那个，测试直接调这个。
    ///
    /// 「解出暂存项 → 压成一个 ZIP」整段都在队列里，而不是只有最后一步：
    /// 以前它自己起一个 Task，压大目录时点打包会真的并行跑两个进程，
    /// 取消也管不着它。
    func packStash(to output: URL) {
        guard !stash.isEmpty else { return }
        let items = stash
        let passwordMap = passwords
        submitJob(title: "正在打包暂存", detail: output.lastPathComponent) { [weak self] jobID in
            guard let self else { return .cancelled }
            return await self.runStashPackJob(output: output, items: items,
                                              passwords: passwordMap, jobID: jobID)
        }
    }

    /// 暂存打包的执行体。每一步都可能失败，失败了就停：
    /// 以前解压用 `try?` 吞掉错误，照样把「预期路径」塞进打包清单，
    /// 最后得到一个缺文件的包，用户还以为是成功的。
    private func runStashPackJob(output: URL, items: [StashItem],
                                 passwords passwordMap: [String: String],
                                 jobID: UUID) async -> JobResult {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-stash-\(UUID().uuidString)", isDirectory: true)
        // 成功、失败、取消都从这里收尾：临时解出来的东西一个不留
        defer { try? FileManager.default.removeItem(at: staging) }

        func checkCancelled() throws {
            if TaskRegistry.wasCancelled(jobID) { throw ArchiveError.cancelled }
        }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            var files: [URL] = []
            for (index, item) in items.enumerated() {
                try checkCancelled()
                status = "正在解压暂存项 \(index + 1)/\(items.count)…"

                let folder = staging.appendingPathComponent(
                    item.archive.deletingPathExtension().lastPathComponent, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ArchiveService.extract(item.archive, entries: [item.path],
                                                   to: folder,
                                                   password: passwordMap[item.archive.path],
                                                   jobID: jobID)
                    }.value
                } catch ArchiveError.cancelled {
                    throw ArchiveError.cancelled
                } catch {
                    // 是哪个文件、为什么，一样都不能省：打包结果得对得上用户的预期
                    throw ArchiveError.tool("「\(item.name)」解压失败：\(error.localizedDescription)")
                }

                var file = folder.appendingPathComponent(item.path)
                // 引擎没报错但文件不在，同样算失败——继续压只会漏文件
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw ArchiveError.tool("「\(item.name)」没有解出来，已停止打包")
                }
                // 同名时加包名前缀：7-Zip 不接受两个不同目录下的同名文件
                let ext = file.pathExtension
                let base = file.deletingPathExtension().lastPathComponent
                let renamed = folder
                    .appendingPathComponent("\(base)-\(item.archive.deletingPathExtension().lastPathComponent)")
                    .appendingPathExtension(ext)
                if (try? FileManager.default.moveItem(at: file, to: renamed)) != nil {
                    file = renamed
                }
                files.append(file)
            }

            // 解压阶段耗掉的时间里用户可能已经点了取消，别再往下压了
            try checkCancelled()
            status = "正在打包 \(files.count) 项…"
            let filesToArchive = files
            let onProgress: @Sendable (Double) -> Void = { [weak self] value in
                self?.reportProgress(value, for: jobID)
            }
            try await Task.detached(priority: .userInitiated) {
                try Self.writeArchive(at: output, from: filesToArchive,
                                      format: .zip, password: "", volume: nil,
                                      level: CompressLevel.normal.argument,
                                      jobID: jobID, onProgress: onProgress)
            }.value

            status = "已打包 \(files.count) 项 · \(output.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([output])
            return .succeeded
        } catch ArchiveError.cancelled {
            status = "已取消"
            return .cancelled
        } catch {
            status = "打包失败"
            errorMessage = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    private func finishLocked() {
        isLoading = false
        status = "已加密，未解锁"
    }

    // MARK: - 密码询问

    /// 密码询问改用 SwiftUI 弹窗，不用 NSAlert.runModal。
    /// runModal 会在主线程跑嵌套 runloop，从 async 上下文调用时偶尔根本不显示——
    /// 表现就是「点了加密包，什么都没发生」。
    struct PasswordRequest: Identifiable {
        let id = UUID()
        let archive: URL
        let isRetry: Bool
    }

    @Published var passwordRequest: PasswordRequest?
    /// 非 nil 时主界面弹「创建压缩包」sheet
    @Published var pendingCreate: PendingCreate?

    // MARK: 任务队列
    //
    // 一次只跑一个任务。TaskRegistry 只有一个进程槽，并行会取消错进程，
    // 所以第二个任务排队而不是同时开跑。
    // 这里只负责「排队 + 状态 + 取消 + 延迟显示」，
    // 压缩、解压的具体逻辑仍留在各自方法里，不搬动。

    /// 当前正在跑的任务
    @Published private(set) var job: TaskJob?
    /// 排在自己后面的任务数
    @Published private(set) var queuedCount = 0
    /// 卡片要不要露出来。任务立刻开始，但只有超过 0.8 秒才显示——
    /// 压一个小文件闪一下进度条，比没有进度更烦。
    @Published private(set) var jobVisible = false

    /// 退出流程已经接管：等待收尾或正在取消时，不再接受新的后台任务。
    /// 用户选了「继续使用」会复位（见 resumeAfterAbortedTermination）。
    @Published private(set) var isTerminating = false
    /// 队列排空时回调一次，退出协调用它决定什么时候真正退出
    var onWorkDrained: (() -> Void)?

    private var jobQueue: [PendingJob] = []
    private var jobBusy = false
    private var jobReveal: Task<Void, Never>?

    /// 正在跑 + 排队中的任务数
    var pendingJobCount: Int { (job == nil ? 0 : 1) + jobQueue.count }

    /// 有没有还没收尾的活：队列任务，或预览解压 / 缩略图这类临时写入。
    /// ⌘Q 要不要拦下来问一句，看的就是它。
    var hasUnfinishedWork: Bool {
        pendingJobCount > 0 || ScratchUsage.shared.isWorking
    }

    /// 提交一个任务。前一个没跑完就排队。
    /// 退出等待期间直接拒绝：此时再塞进来的任务没人等它，退出也不会为它延后。
    func submitJob(title: String, detail: String,
                   work: @escaping @MainActor (UUID) async -> JobResult) {
        guard !isTerminating else {
            status = "正在退出，未提交新任务"
            return
        }
        jobQueue.append(PendingJob(id: UUID(), title: title, detail: detail, work: work))
        queuedCount = jobQueue.count
        // 当前任务已经在跑时，卡片上的「还有 N 个」要跟着涨
        job?.queued = jobQueue.count
        pumpJobs()
    }

    /// 只取消当前任务。串行执行保证 TaskRegistry 里的进程就是它，
    /// 不会出现「两个任务同时跑、取消关错进程」。
    func cancelJob() {
        guard let job else { return }
        status = "正在取消…"
        // 带 ID：只终止这个任务的进程。批量/预览那些临时进程不归队列管，
        // 不会被这里误杀。
        TaskRegistry.cancel(job.id)
    }

    /// 执行体在后台线程回调，切回主线程写进对应任务。
    /// 带 ID 是为了丢弃上一个任务迟到的进度。
    nonisolated func reportProgress(_ value: Double, for id: UUID) {
        Task { @MainActor in
            guard job?.id == id else { return }
            job?.fraction = value
        }
    }

    private func pumpJobs() {
        guard !jobBusy, !jobQueue.isEmpty else { return }
        jobBusy = true
        let next = jobQueue.removeFirst()
        queuedCount = jobQueue.count

        do {
            // 提交后、进程启动前就被取消的情况，在这里拦下来，连进程都不启动
            try TaskRegistry.claim(next.id)
        } catch {
            // 还没开始执行就被取消：work 根本没跑，状态得在这里收
            jobBusy = false
            status = "已取消"
            finishJob(.cancelled)
            return
        }

        job = TaskJob(id: next.id, title: next.title, detail: next.detail, queued: jobQueue.count)
        isLoading = true

        jobVisible = false
        jobReveal?.cancel()
        jobReveal = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled, self.job?.id == next.id else { return }
            withAnimation(.easeOut(duration: 0.18)) { self.jobVisible = true }
        }

        Task {
            let result = await next.work(next.id)
            self.finishJob(result)
        }
    }

    private func finishJob(_ result: JobResult) {
        jobReveal?.cancel()
        jobReveal = nil
        jobVisible = false
        let finishedID = job?.id
        job = nil
        jobBusy = false

        // 任务到此结束，才释放进程归属。子进程退出时只注销那一个进程
        // （见 TaskRegistry.endProcess），否则加密解压的第二次重试就取消不了了。
        if let finishedID { TaskRegistry.release(finishedID) }

        if case .failed(let message) = result {
            errorMessage = message
            // 状态文案由执行体自己写（「压缩失败」「打包失败」「解压失败」），
            // 这里再盖一个「失败」只会把话说得更含糊
        }
        // 队列里还有就接着跑
        pumpJobs()
        // 忙碌状态由队列决定：还有下一个就继续转，全部跑完才停。
        // 让每个任务自己复位会在排队时提前把 spinner 关掉。
        isLoading = job != nil

        // 只有退出流程才关心「排空」这个时刻：通知恰好一次，避免重复 reply
        guard isTerminating, job == nil, jobQueue.isEmpty else { return }
        let drained = onWorkDrained
        onWorkDrained = nil
        drained?()
    }

    private var passwordContinuation: CheckedContinuation<String?, Never>?

    private func askPassword(for archive: URL, wrong: Bool) async -> String? {
        return await withCheckedContinuation { continuation in
            passwordContinuation = continuation
            passwordRequest = PasswordRequest(archive: archive, isRetry: wrong)
        }
    }

    /// 弹窗回调；nil 表示取消
    func submitPassword(_ value: String?) {
        guard passwordRequest != nil else { return }
        passwordRequest = nil
        passwordContinuation?.resume(returning: value)
        passwordContinuation = nil
    }

    // MARK: - 嵌套浏览

    func enter(_ entry: ArchiveEntry) {
        guard entry.isArchive, current != nil else { return }
        isLoading = true
        status = "正在展开 \(entry.name)…"

        Task {
            guard let extracted = await extractNested(entry) else {
                isLoading = false
                status = "展开失败"
                return
            }
            isLoading = false
            loadFrame(url: extracted, resetTrail: false)
        }
    }

    /// 把内层包解到临时目录，并且**带着占用**返回它的路径。
    ///
    /// 占用必须从「解压写完」一直挂到 `performLoad` 结束——那之前的内层包
    /// 既不在 `active` 里（写入已结束），也不在 `trail` 里（还没进浏览状态），
    /// 中间任何一次自动回收都能把它删掉。释放点在 `performLoad` 的 defer，
    /// 成功、读失败、等密码时取消都会走到。失败路径不留下任何登记。
    func extractNested(_ entry: ArchiveEntry) async -> URL? {
        guard entry.isArchive, let frame = current else { return nil }
        let archive = frame.archive
        let passphrase = passwords[archive.path]
        let engine = frame.engine
        let path = entry.path
        let scratch = self.scratch

        do {
            return try await Task.detached { () -> URL in
                let dir = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                // 解压在往这个目录里写，回收不许进来
                ScratchUsage.shared.beginWork(on: dir.path)
                defer { ScratchUsage.shared.endWork(on: dir.path) }
                switch engine {
                case .libarchive:
                    try Tar.extract(archive, entries: [path], to: dir, passphrase: passphrase)
                case .sevenZip:
                    try SevenZip.extract(archive, entries: [path], to: dir, password: passphrase)
                }
                let inside = dir.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: inside.path) else {
                    throw ArchiveError.tool("未能展开 \(path)")
                }
                // 交给主线程之后，这个文件还要等异步列表才进 trail：先占住
                ScratchUsage.shared.hold(inside)
                return inside
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return nil
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

    /// 设置里的固定目录。`problem` 非空表示用户设过、但现在用不了，
    /// 要明确告诉他而不是静默弹面板——他不知道自己的设置为什么没生效。
    private var fixedExtractDestination: (url: URL?, problem: String?) {
        let raw = UserDefaults.standard.string(forKey: ExtractDestinationSetting.defaultsKey) ?? ""
        let resolution = ExtractDestinationSetting.resolve(raw)
        return (resolution.url, resolution.problem)
    }

    func extractAll() {
        guard let frame = current else { return }
        guard let destination = resolveDestination(message: "选择解压目标文件夹") else { return }
        extract(entries: [], from: frame, to: destination)
    }

    /// 固定目录优先；没设或失效才弹面板。返回 nil = 用户取消，调用方直接返回。
    private func resolveDestination(message: String) -> URL? {
        let fixed = fixedExtractDestination
        if let problem = fixed.problem { notice = problem }
        if let url = fixed.url { return url }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到此处"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    func extractSelection() {
        guard let frame = current else { return }
        let chosen = entries.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        guard let destination = resolveDestination(message: "解压选中的 \(chosen.count) 个项目") else {
            return
        }
        extract(entries: chosen.map(\.path), from: frame, to: destination)
    }

    private func extract(entries paths: [String], from frame: Frame, to destination: URL) {
        submitJob(title: "正在解压", detail: frame.archive.lastPathComponent) { [weak self] jobID in
            guard let self else { return .cancelled }
            self.status = "正在解压…"
            var passphrase = self.passwords[frame.archive.path]

            for attempt in 0..<2 {
                do {
                    let currentPassphrase = passphrase
                    let onProgress: @Sendable (Double) -> Void = { [weak self] value in
                        self?.reportProgress(value, for: jobID)
                    }
                    try await Task.detached {
                        switch frame.engine {
                        case .libarchive:
                            // tar 没有进度输出，界面保持不确定态
                            try Tar.extract(frame.archive, entries: paths, to: destination,
                                            passphrase: currentPassphrase, jobID: jobID)
                        case .sevenZip:
                            try SevenZip.extract(frame.archive, entries: paths, to: destination,
                                                 password: currentPassphrase,
                                                 jobID: jobID,
                                                 onProgress: onProgress)
                        }
                    }.value
                    self.status = "已解压到 \(destination.lastPathComponent)"
                    // 设置里可以关掉「解压后在访达中显示」
                    if UserDefaults.standard.object(forKey: "rrzip.revealAfterExtract") as? Bool ?? true {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                    return .succeeded
                } catch ArchiveError.cancelled {
                    // 用户主动取消不是失败，不弹错误框。
                    // 解压没法像压缩那样回滚：已写出的文件留在目标目录里，
                    // 与其假装干净，不如直接说清楚。
                    self.status = "已取消，目标目录可能留有部分文件"
                    return .cancelled
                } catch let ArchiveError.tool(message) where Tar.looksEncrypted(message) {
                    guard attempt == 0,
                          let typed = await self.askPassword(for: frame.archive,
                                                            wrong: passphrase != nil) else {
                        self.errorMessage = "密码错误或已取消"
                        self.status = "解压失败"
                        return .failed("密码错误或已取消")
                    }
                    passphrase = typed
                    self.passwords[frame.archive.path] = typed
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.status = "解压失败"
                    return .failed(error.localizedDescription)
                }
            }
            return .failed("解压失败")
        }
    }

    /// 拖拽导出 / 预览用的临时文件（带缓存，同一份文件不重复解压）
    /// 异步版：预览面板和「另存为」都要等这份临时副本，
    /// 以前各自写一遍 withCheckedContinuation，收成一份
    func payloadURL(for entry: ArchiveEntry) async -> URL? {
        let url: URL? = await withCheckedContinuation { continuation in
            payloadURL(for: entry) { result in
                // 交接期先兜住：回调返回后解压目录的登记就撤了，而等待者要等到
                // 下一轮 MainActor 才继续跑。这中间的副本既不在 active 也不在人手里。
                if let result { ScratchUsage.shared.hold(result) }
                continuation.resume(returning: result)
            }
        }
        // 调用方在同一轮次里接着用（自己 hold，或者立刻读），到这里交接可以放
        if let url { ScratchUsage.shared.release(url) }
        return url
    }

    func payloadURL(for entry: ArchiveEntry, completion: @escaping (URL?) -> Void) {
        guard let frame = current else { return completion(nil) }

        let key = cacheKey(entry, in: frame)
        if let cached = payloadCache[key], FileManager.default.fileExists(atPath: cached.path) {
            markUsed(cached)
            return completion(cached)
        }

        // 详情栏、缩略图、悬停预览常常同时要同一份文件。第一份还在解的时候
        // 后来的人只排队等结果，不再各自起一次 7zz / tar。
        if payloadWaiters[key] != nil {
            payloadWaiters[key]?.append(completion)
            return
        }
        payloadWaiters[key] = [completion]

        let destination = freshScratch()
        let passphrase = passwords[frame.archive.path]
        let engine = frame.engine
        // 预览解压不走任务队列，清缓存看不到它。先在这里登记，
        // 再派任务——顺序反了就没用：调用方紧接着清缓存会漏判。
        // 带目录登记：自动回收也要知道这一份还在写，别删人家的半成品。
        ScratchUsage.shared.beginWork(on: destination.path)
        Task {
            defer { ScratchUsage.shared.endWork(on: destination.path) }
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
                payloadCache[key] = url
                // 磁盘软预算：按字节回收最久未用的临时副本。
                // 这一次的目录还在 beginWork 里登记着，回收跳不过去就超预算，不会删它
                trimScratch()
            }
            // 失败的路径也要把等待者全部放走：留一个就永久挂着
            for waiter in payloadWaiters.removeValue(forKey: key) ?? [] {
                waiter(url)
            }
        }
    }

    /// 按字节回收 `scratch`：正在被界面占用的、正在写入的、正在浏览的嵌套包都不动。
    /// 候选全被占用就允许暂时超预算，不做「反复解压再删除」这种事。
    private func trimScratch() {
        let keep = Set(trail.compactMap { unit(of: $0.archive) })
        CacheMaintenance.trim(scratch, budget: Self.payloadDiskBudget, keep: keep)
        // 回收掉的目录在索引里也得摘掉，否则字典只增不减、还会指向已删文件
        prunePayloadIndex()
    }

    /// 索引只留还真实存在的副本。每次回收顺带跑一遍，开销是一次 stat。
    private func prunePayloadIndex() {
        payloadCache = payloadCache.filter { FileManager.default.fileExists(atPath: $0.value.path) }
    }

    /// 丢掉一份不再需要的临时副本：从索引里摘掉，并标记为「优先回收」。
    ///
    /// 不在这里直接删目录：这份副本可能同一时刻已经交给了快速查看、缩略图或
    /// 另存为，它们还没来得及 hold。硬删就是抽走别人手里的文件；改成把目录
    /// 时间戳打到最早，下一次回收优先带走它。
    func discardPayload(_ url: URL) {
        payloadCache = payloadCache.filter { $0.value.path != url.path }
        guard let dir = unit(of: url) else { return }
        CacheMaintenance.touch(dir, at: .distantPast)
    }

    /// 索引里还认得的副本数（测试与诊断用）
    var cachedPayloadCount: Int { payloadCache.count }

    /// 缓存命中时刷新「最近使用时间」，回收按这个时间排序才是真的 LRU
    private func markUsed(_ url: URL) {
        guard let dir = unit(of: url) else { return }
        CacheMaintenance.touch(dir)
    }

    /// 副本所在的顶层目录：`scratch/<UUID>/任意层/文件` → `scratch/<UUID>`。
    /// 回收、丢弃、刷新时间都以它为单位——条目带子目录时只删一层会留下空壳。
    private func unit(of url: URL) -> String? {
        CacheMaintenance.unit(of: url.path, in: scratch)
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
        volume: String?,
        level: Int = 5,
        jobID: UUID? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
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

        // 「必须 7zz」和「优先 7zz」要分开：
        // 7z / 加密 / 分卷 没有 7zz 就做不了，必须报错；
        // ZIP 只是想要 -mx —— bsdtar 的 zip 写入只 store，四档级别等于摆设
        // （选「极限」和「存储」压出来一样大），所以 ZIP 也走 7zz，
        // 但没 7zz 时还能退回 ditto，不该直接失败。
        let requiresSevenZip = format.usesSevenZip || !password.isEmpty || volume != nil
        let prefersSevenZip = format == .zip && SevenZip.isAvailable

        do {
            if requiresSevenZip {
                guard SevenZip.isAvailable else { throw ArchiveError.engineUnavailable }
                try SevenZip.create(
                    at: staged, from: items,
                    format: format == .sevenZip ? "7z" : format.ext,
                    password: password.isEmpty ? nil : password,
                    volume: volume,
                    level: level,
                    jobID: jobID,
                    onProgress: onProgress
                )
            } else if prefersSevenZip {
                try SevenZip.create(
                    at: staged, from: items,
                    format: format.ext,
                    password: nil,
                    volume: nil,
                    level: level,
                    jobID: jobID,
                    onProgress: onProgress
                )
            } else if format == .zip {
                // 没有 7zz 时：单源还能用 ditto 撑住（deflate，但选不了级别）；
                // 多源只剩 bsdtar 的 store，四档级别彻底失效。
                // 与其静默给一个「压了等于没压」的包，不如明说引擎缺失。
                guard items.count == 1 else { throw ArchiveError.engineUnavailable }
                try Tar.createZip(at: staged, from: items[0], jobID: jobID)
            } else {
                // TAR / TGZ 走 bsdtar。它也支持取消：
                // 不传 jobID 的话，这两个格式的任务按「取消」不会有任何反应。
                try Tar.create(at: staged, from: items, format: format.ext, jobID: jobID)
            }
            // 压完了但取消信号刚好赶到：这时候交出产物等于没取消。
            // 拿掉这一行，用户点了取消却仍然得到一个包（旧的同名包还会被替换）。
            if let jobID, TaskRegistry.wasCancelled(jobID) { throw ArchiveError.cancelled }
            // 从这里开始是不可中断的收尾：要么整组换上去，要么按
            // commitStaged 里的备份 / 回滚收场。分卷是多文件，中途被打断
            // 就会两头空，所以这一段刻意不再看取消信号。
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

        if hasVolumes {
            // 旧分卷先改名成备份，不能直接删。
            // 分卷是多文件，没有原子替换可用：以前是「先删旧的、再移新的」，
            // 移到一半失败（磁盘满、进程被杀、权限变了）就两头空——
            // 用户原来的包没了，新的也不完整。
            let oldVolumes = volumeFiles(of: output)
            let token = String(UUID().uuidString.prefix(8))
            var backups: [(original: URL, backup: URL)] = []

            for old in oldVolumes {
                let backup = folder.appendingPathComponent(
                    old.lastPathComponent + ".rrzip-old-" + token)
                do {
                    try fm.moveItem(at: old, to: backup)
                    backups.append((old, backup))
                } catch {
                    // 备份都做不成，把已经改名的还回去，原样退出
                    for (original, backup) in backups {
                        try? fm.moveItem(at: backup, to: original)
                    }
                    throw error
                }
            }

            do {
                try moveVolumeFiles(from: staged, to: output)
            } catch {
                // 回滚：清掉刚移进去的新分卷，再把旧分卷改回来
                for new in volumeFiles(of: output) { try? fm.removeItem(at: new) }
                for (original, backup) in backups {
                    try? fm.moveItem(at: backup, to: original)
                }
                throw error
            }

            for (_, backup) in backups { try? fm.removeItem(at: backup) }
        } else if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: output)
        }
    }

    /// 旧分卷：只认 `foo.zip.001` 这种纯数字后缀。
    /// 以前用 `hasPrefix(outName + ".")`，`foo.zip.bak`、`foo.zip.old` 都会被当成分卷删掉。
    nonisolated static func volumeFiles(of output: URL) -> [URL] {
        let fm = FileManager.default
        let folder = output.deletingLastPathComponent()
        let outName = output.lastPathComponent
        guard let siblings = try? fm.contentsOfDirectory(at: folder,
                                                        includingPropertiesForKeys: nil) else {
            return []
        }
        return siblings.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(outName + ".") else { return false }
            let rest = name.dropFirst(outName.count + 1)
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 把 `staged.001 / staged.002…` 依次改名成 `output.001 / output.002…`
    nonisolated static func moveVolumeFiles(from staged: URL, to output: URL) throws {
        let fm = FileManager.default
        let folder = output.deletingLastPathComponent()
        let stagedName = staged.lastPathComponent
        let outName = output.lastPathComponent

        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(stagedName + ".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            // 一个分卷都没生成，说明 7zz 那边出了问题；别把旧的删了当成功
            throw ArchiveError.tool("分卷产物缺失：\(stagedName).001")
        }

        for file in files {
            let suffix = file.lastPathComponent.dropFirst(stagedName.count)
            try fm.moveItem(at: file,
                            to: folder.appendingPathComponent(outName + suffix))
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
        // 参数交给 SwiftUI sheet；确认后由 finishCreate 选落点并写盘
        pendingCreate = PendingCreate(items: picker.urls)
    }

    /// sheet 确认后：选保存位置并写盘（items 由调用方带过来，此时 sheet 已关）
    func finishCreate(_ options: CreateOptions, items: [URL]) {
        guard !items.isEmpty else { return }

        let save = NSSavePanel()
        save.message = "保存压缩包"
        save.nameFieldStringValue = defaultName(for: items, format: options.format)
        guard save.runModal() == .OK, let picked = save.url else { return }
        var target = picked
        if target.pathExtension.lowercased() != options.format.ext {
            target = target.deletingPathExtension().appendingPathExtension(options.format.ext)
        }
        let output = target

        // tar / tgz 不支持密码与分卷，选项里先关掉了，这里再兜一层
        let plain = options.format == .tar || options.format == .tgz
        let password = plain ? "" : options.password
        let volume = plain ? nil : options.volume.argument

        // 分卷包在保存面板里是「看不见」的：目录里只有 abc.zip.001，
        // 没有 abc.zip 这个实体，所以面板不会提示「已存在」。
        // 但提交时会把整组旧分卷换掉——补一次确认，别让它变成静默覆盖。
        if volume != nil {
            let existing = ArchiveModel.volumeFiles(of: output)
            if !existing.isEmpty {
                let alert = NSAlert()
                alert.messageText = "已存在同名的分卷压缩包"
                alert.informativeText = "\(output.lastPathComponent).001 等 \(existing.count) 个文件会被替换。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "替换")
                alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }

        submitJob(title: "正在压缩", detail: output.lastPathComponent) { [weak self] jobID in
            guard let self else { return .cancelled }
            return await self.runArchiveJob(
                output: output, items: items, format: options.format,
                password: password, volume: volume, level: options.level.argument,
                runningText: "正在压缩…", doneVerb: "已创建",
                jobID: jobID
            )
        }
    }

    private func defaultName(for items: [URL], format: CreateFormat) -> String {
        let base = items.count == 1
            ? items[0].deletingPathExtension().lastPathComponent
            : "归档"
        return "\(base).\(format.ext)"
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

// MARK: - 退出协调

/// 退出流程真正动手的地方。判定与顺序都在 `TerminationCoordinator` 里，
/// 这里只负责「按模型当前的队列做」：
/// - 等待：只禁新任务，队列照旧往下跑
/// - 取消：清空队列 + 终止当前子进程，但**等执行体自己收尾**
///   （压缩要跑 `writeArchive` 的临时文件清理，暂存打包要跑 staging 的 defer）
extension ArchiveModel: TerminationHost {
    var isWritingScratch: Bool { ScratchUsage.shared.isWorking }

    func beginTerminationWait() {
        isTerminating = true
    }

    func cancelWorkForTermination() {
        isTerminating = true

        // 1. 排队的一条都不许再启动。清完 pumpJobs 就没有下家
        jobQueue.removeAll()
        queuedCount = 0
        job?.queued = 0

        // 2. 卡在密码输入上的任务要先放走：continuation 一直挂着，
        //    这个任务永远不会结束，退出就会卡死在「等待收尾」。
        if passwordRequest != nil {
            submitPassword(nil)
        }

        // 3. 正在跑的交给 TaskRegistry 终止子进程。这里不能直接退进程：
        //    压缩正在写临时文件、暂存打包正在写 staging 目录，
        //    要等执行体捕获取消、自己把 defer 清理跑完。
        guard let job else { return }
        status = "正在取消…"
        TaskRegistry.cancel(job.id)
    }

    func resumeAfterAbortedTermination() {
        isTerminating = false
    }
}

/// 内嵌预览（详情栏 / 悬停）的大小上限。
///
/// 音频、视频要整份解压到临时目录才能播，超过上限的条目一旦解压就是几百 MB
/// 的磁盘写入和 I/O，最后还是播不了。所以先按条目大小判断，再决定动不动解压。
enum InlinePreviewLimits {
    static let media: Int64 = 800 * 1024 * 1024
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mpg", "mpeg"]
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"]

    static func isMedia(_ ext: String) -> Bool {
        videoExts.contains(ext) || audioExts.contains(ext)
    }

    /// 已知大小超过上限：不解压，也不生成临时副本。
    ///
    /// 大小未知（`size < 0`，个别归档不写这一列）时判不了，仍然解压，
    /// 由调用方拿到临时文件后按实际大小复核——宁可白解一次，也不能凭猜测
    /// 把本来能预览的文件挡在门外。
    static func skipsExtraction(_ entry: ArchiveEntry) -> Bool {
        isMedia(entry.ext) && entry.size >= 0 && entry.size > media
    }
}
