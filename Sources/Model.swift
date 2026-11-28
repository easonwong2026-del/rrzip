// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Observation
import Foundation
import SwiftUI

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

/// 首页「最近打开」的一条。非沙盒应用按路径记就够，失效时置灰提示。
struct RecentArchive: Identifiable, Codable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let openedAt: Date
    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor
@Observable
final class ArchiveModel {

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

    private(set) var trail: [Frame] = []
    var selection: Set<ArchiveEntry.ID> = [] {
        didSet { archiveIndex.invalidateSelection() }
    }
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            // 关键词一变，列表内容整批换掉：留着已经看不见的选中项，
            // 预览是空的、底部却写「已选 N 项」，删除还会作用到不可见的条目
            pruneSelectionToDisplayed()
        }
    }
    /// 键盘导航计数。视图只在它变化时才把选中行滚进视口；
    /// 单击 / ⌘ 多选 / ⇧ 连选 / ⌘A 一律不动滚动位置。
    private(set) var keyboardScrollTick: Int = 0
    /// 布局切换计数（视图形态 / 简化模式）。视图换了主体就重建了，
    /// 新滚动容器的「首次同步」不能当作滚动信号，得等布局落地后再补一次定位。
    private(set) var layoutTick: Int = 0
    var viewMode: ArchiveViewMode = .list {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "rrzip.viewMode")
            if viewMode != oldValue { layoutTick &+= 1 }
        }
    }
    /// 列表排序：点表头切换列，再点一次换方向
    var sortKey: SortKey = .name {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: "rrzip.sortKey")
            archiveIndex.invalidateOrder()
        }
    }
    var sortAscending = true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: "rrzip.sortAscending")
            archiveIndex.invalidateOrder()
        }
    }
    var appearance: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "rrzip.appearance") }
    }
    /// 简化 / 完整模式。放在 model 里而不是视图里，切换模式不会重建状态机
    var workspaceMode: WorkspaceMode = .compact {
        didSet {
            UserDefaults.standard.set(workspaceMode.rawValue, forKey: "rrzip.workspaceMode")
            if workspaceMode != oldValue { layoutTick &+= 1 }
        }
    }
    /// 最近一次「手动」切模式的时刻。自适应布局在这之后 5 分钟内不抢控制权
    private(set) var modePinnedAt: Date = .distantPast
    var isCompactMode: Bool { workspaceMode == .compact }
    /// 每次重新点同一行就自增，强制预览刷新
    private(set) var previewToken: Int = 0
    private(set) var isLoading = false
    func setArchiveEditing(_ editing: Bool) { isLoading = editing }
    var status: String = "拖入一个压缩包，或按 ⌘O 打开"
    var errorMessage: String?
    /// 一次性浮条提示：不打断操作，3 秒后自动消失。
    /// 用于「另有 N 个压缩包未打开」这类需要告知但不需要弹窗的情况。
    var notice: String?
    private(set) var unlocked: Set<String> = []
    /// 非空时弹出批量面板
    var batchRequest: BatchRequest?

    /// 暂存区：跨层、跨包攒起来，最后一次性导出
    let stashStore: StashStore
    var stash: [StashItem] { stashStore.items }
    func updateStash(_ change: (inout [StashItem]) -> Void) { stashStore.update(change) }
    var isStashVisible = false
    /// 暂存导出的落盘方式
    var stashLayout: StashLayout {
        get { stashStore.layout }
        set { stashStore.layout = newValue }
    }

    /// 首页「最近打开」，最多 8 条
    private(set) var recentArchives: [RecentArchive] = []

    var current: Frame? { trail.last }
    /// 当前层是不是嵌套包里的临时副本
    var isNested: Bool { current?.isNested ?? false }
    var entries: [ArchiveEntry] { current?.entries ?? [] }
    var canGoBack: Bool { trail.count > 1 }

    let archiveIndex = ArchiveIndex()

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

    private(set) var passwords: [String: String] = [:]

    let sessionID = UUID()
    @ObservationIgnored var routeOpen: (([URL], ArchiveModel) -> Void)?
    @ObservationIgnored var passwordFromOtherWindows: ((URL) -> String?)?
    private(set) var windowClosed = false

    init(stashStore: StashStore? = nil) {
        self.stashStore = stashStore ?? StashStore()
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
    private let payloads = PayloadCache()
    static let payloadDiskBudget = PayloadCache.diskBudget

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
        loadRecentArchives()
        var list = recentArchives.filter { $0.path != url.path }
        list.insert(RecentArchive(path: url.path, name: url.lastPathComponent, openedAt: Date()), at: 0)
        recentArchives = Array(list.prefix(8))
        saveRecentArchives()
    }

    func removeRecent(_ item: RecentArchive) {
        loadRecentArchives()
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

    func cacheSizeOnDisk() -> Int64 { payloads.sizeOnDisk() }

    @discardableResult
    func clearCaches() -> CacheCleanupReport {
        let report = payloads.clear(busy: job != nil || !jobQueue.isEmpty)
        if !report.blocked {
            ThumbnailStore.shared.clear()
            status = report.text
        }
        return report
    }

    // MARK: - 打开

    func open(url: URL) {
        if let routeOpen { return routeOpen([url], self) }
        openInSession(url)
    }

    func openInSession(_ url: URL) {
        guard !windowClosed else { return }
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
        panel.message = "选择要打开的压缩包"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        if let routeOpen {
            routeOpen(urls, self)
        } else if urls.count > 1 {
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
        let name = frame.archive.lastPathComponent
        submitJob(title: "正在校验", detail: name) { [weak self] jobID in
            guard let self else { return .cancelled }
            self.status = "正在校验 \(name)…"
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.verify(frame.archive, password: password, jobID: jobID)
                }.value
                try TaskRegistry.checkCancellation(jobID)
                self.status = "校验通过 · \(name)"
                return .succeeded
            } catch ArchiveError.cancelled {
                self.status = "已取消校验"
                return .cancelled
            } catch {
                self.status = "校验失败"
                return .failed(error.localizedDescription)
            }
        }
    }

    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var openingArchive: URL?
    var rootArchive: URL? { openingArchive ?? trail.first?.archive }
    var canReuseWindow: Bool {
        rootArchive == nil && !isLoading && passwordRequest == nil
            && batchRequest == nil && pendingCreate == nil && errorMessage == nil
    }

    func loadFrame(url: URL, resetTrail: Bool, restorePrefix: String? = nil) {
        guard !windowClosed else {
            if !resetTrail { ScratchUsage.shared.release(url) }
            return
        }
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        openingArchive = resetTrail ? url : nil
        isLoading = true
        status = "正在读取 \(url.lastPathComponent)…"
        loadTask = Task {
            defer {
                if loadGeneration == generation { openingArchive = nil }
            }
            await performLoad(
                url: url,
                resetTrail: resetTrail,
                restorePrefix: restorePrefix,
                generation: generation
            )
        }
    }

    private func performLoad(
        url: URL,
        resetTrail: Bool,
        restorePrefix: String? = nil,
        generation: UInt64
    ) async {
        // 嵌套包在 enter() 里挂过占用：从解压完成一直兜到它进 trail。
        // 这里所有出口（成功、读失败、等密码时被取消）都要放掉，否则那份临时
        // 目录永远占着、回收也动不了它。非嵌套包的路径上没有 hold，release 是空操作。
        defer { ScratchUsage.shared.release(url) }

        var passphrase = passwords[url.path]
        let detection = FormatDetector.detect(url)
        var listing: (entries: [ArchiveEntry], engine: ArchiveEngine)?
        while generation == loadGeneration, !Task.isCancelled {
            do {
                let password = passphrase
                listing = try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.listWithEngine(url, password: password)
                }.value
                break
            } catch ArchiveError.needsPassword {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                let typed = await askPassword(for: url, wrong: passphrase != nil)
                guard generation == loadGeneration, !Task.isCancelled else { return }
                guard let typed else { return finishLocked() }
                passphrase = typed
            } catch {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                isLoading = false
                status = "读取失败"
                errorMessage = error.localizedDescription
                return
            }
        }

        // 若加载期间已切换到另一个归档，静默丢弃过期结果，防止 ABA 覆写新状态
        guard generation == loadGeneration, !Task.isCancelled else { return }

        guard let (entries, engine) = listing else {
            isLoading = false
            status = "读取失败"
            return
        }

        if let passphrase {
            passwords[url.path] = passphrase
            stashStore.remember(passphrase, for: url)
            unlocked.insert(url.path)
        }
        let attrs = await Task.detached {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (values?.fileSize.map(Int64.init), values?.contentModificationDate)
        }.value
        guard generation == loadGeneration, !Task.isCancelled else { return }
        let frame = Frame(
            archive: url, entries: entries, engine: engine, detection: detection,
            isNested: !resetTrail,
            archiveSize: attrs.0,
            archiveModified: attrs.1
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
        let remaining = pending.archives.filter { $0 != url.path }
        if remaining.isEmpty {
            PendingExtraction.clear()
        } else {
            PendingExtraction.write(archives: remaining.map { URL(fileURLWithPath: $0) }, mode: pending.mode)
        }

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

    var passwordRequest: PasswordRequest?
    /// 非 nil 时主界面弹「创建压缩包」sheet
    var pendingCreate: PendingCreate?

    // MARK: 任务队列
    //
    // 主窗口的队列按顺序运行，批量面板的子进程另按各自的任务 ID 跟踪。
    // 这里只负责「排队 + 状态 + 取消 + 延迟显示」，
    // 压缩、解压的具体逻辑仍留在各自方法里，不搬动。

    /// 当前正在跑的任务
    private(set) var job: TaskJob?
    var finderJob: TaskJob?
    @ObservationIgnored var cancelFinderTask: (() -> Void)?
    /// 排在自己后面的任务数
    private(set) var queuedCount = 0
    /// 卡片要不要露出来。任务立刻开始，但只有超过 0.8 秒才显示——
    /// 压一个小文件闪一下进度条，比没有进度更烦。
    private(set) var jobVisible = false

    /// 退出流程已经接管：等待收尾或正在取消时，不再接受新的后台任务。
    /// 用户选了「继续使用」会复位（见 resumeAfterAbortedTermination）。
    private(set) var isTerminating = false
    /// 队列排空时回调一次，退出协调用它决定什么时候真正退出
    var onWorkDrained: (() -> Void)?
    @ObservationIgnored var onClosedJobDrained: (() -> Void)?

    private var jobQueue: [PendingJob] = []
    private var jobBusy = false
    private var jobReveal: Task<Void, Never>?

    /// 正在跑 + 排队中的任务数
    var pendingJobCount: Int { (job != nil || passwordRequest != nil ? 1 : 0) + jobQueue.count }

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

        notifyWorkDrainedIfNeeded()
        if windowClosed, pendingJobCount == 0 { onClosedJobDrained?() }
    }

    /// 退出流程的「排空」判定：队列空了、且没有正在写的正式文件，才通知一次。
    /// 原地编辑与访达服务不走队列，所以不能只看 job。
    func notifyWorkDrainedIfNeeded() {
        guard isTerminating, pendingJobCount == 0 else { return }
        guard FormalWriteLedger.shared.isEmpty else { return }
        let drained = onWorkDrained
        onWorkDrained = nil
        drained?()
    }

    private struct PendingPasswordPrompt {
        let request: PasswordRequest
        let continuation: CheckedContinuation<String?, Never>
    }

    private var activePasswordPrompt: PendingPasswordPrompt?
    private var passwordPromptQueue: [PendingPasswordPrompt] = []

    /// 悬起一个密码询问。采用 FIFO 队列串行展示，避免后台解压与前台打开
    /// 同时触发密码弹窗时互相覆盖 continuation 导致崩溃或队列死锁。
    func askPassword(for archive: URL, wrong: Bool) async -> String? {
        let request = PasswordRequest(archive: archive, isRetry: wrong)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                let item = PendingPasswordPrompt(request: request, continuation: continuation)
                if activePasswordPrompt == nil && passwordRequest == nil {
                    activePasswordPrompt = item
                    passwordRequest = request
                } else {
                    passwordPromptQueue.append(item)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelPasswordPrompt(request.id) }
        }
    }

    private func cancelPasswordPrompt(_ id: UUID) {
        if activePasswordPrompt?.request.id == id {
            submitPassword(nil, requestID: id)
        } else if let index = passwordPromptQueue.firstIndex(where: { $0.request.id == id }) {
            passwordPromptQueue.remove(at: index).continuation.resume(returning: nil)
        }
    }

    /// 弹窗回调；nil 表示取消。恢复当前队头后自动弹出下一条排队请求。
    func submitPassword(_ value: String?, requestID: UUID? = nil) {
        if let requestID, requestID != activePasswordPrompt?.request.id { return }
        guard passwordRequest != nil || activePasswordPrompt != nil else { return }
        let currentPrompt = activePasswordPrompt
        activePasswordPrompt = nil
        passwordRequest = nil
        currentPrompt?.continuation.resume(returning: value)

        if !passwordPromptQueue.isEmpty {
            let next = passwordPromptQueue.removeFirst()
            activePasswordPrompt = next
            passwordRequest = next.request
        }
        notifyWorkDrainedIfNeeded()
    }

    /// 退出取消时一次性放行所有挂起的密码询问（含当前弹窗与排队项）
    private func cancelAllPasswordPrompts() {
        let active = activePasswordPrompt
        let queued = passwordPromptQueue
        activePasswordPrompt = nil
        passwordPromptQueue.removeAll()
        passwordRequest = nil
        active?.continuation.resume(returning: nil)
        for item in queued {
            item.continuation.resume(returning: nil)
        }
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
        let dir = payloads.scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ScratchUsage.shared.beginWork(on: dir.path)
        defer { ScratchUsage.shared.endWork(on: dir.path) }

        do {
            return try await Task.detached { () -> URL in
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
                        try ArchiveService.extract(frame.archive, entries: paths, to: destination,
                                                   password: currentPassphrase, jobID: jobID,
                                                   preferredEngine: frame.engine, onProgress: onProgress)
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
                } catch ArchiveError.needsPassword {
                    guard attempt == 0,
                          let typed = await self.askPassword(for: frame.archive,
                                                            wrong: passphrase != nil) else {
                        self.errorMessage = "密码错误或已取消"
                        self.status = "解压失败"
                        return .failed("密码错误或已取消")
                    }
                    passphrase = typed
                    self.passwords[frame.archive.path] = typed
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

    func payloadURL(for entry: ArchiveEntry) async -> URL? {
        guard let frame = current else { return nil }
        return await payloads.url(for: entry, in: frame, password: passwords[frame.archive.path],
                                  retaining: { self.trail.map(\.archive) })
    }

    func payloadURL(for entry: ArchiveEntry, completion: @escaping (URL?) -> Void) {
        guard let frame = current else { return completion(nil) }
        payloads.url(for: entry, in: frame, password: passwords[frame.archive.path],
                     retaining: { self.trail.map(\.archive) }, completion: completion)
    }

    func discardPayload(_ url: URL) { payloads.discardPayload(url) }
    var cachedPayloadCount: Int { payloads.cachedPayloadCount }

    func revealInFinder() {
        guard let frame = current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([frame.archive])
    }

    func lockCurrent() {
        guard let frame = current else { return }
        passwords[frame.archive.path] = nil
        stashStore.forgetPassword(for: frame.archive)
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
    var formalWrites: FormalWriteSummary { FormalWriteLedger.shared.summary() }

    func beginTerminationWait() {
        isTerminating = true
    }

    func cancelWorkForTermination() {
        cancelWindowWork()
        cancelFinderTask?()
    }

    func cancelWindowWork() {
        isTerminating = true

        // 1. 排队的一条都不许再启动。清完 pumpJobs 就没有下家
        jobQueue.removeAll()
        queuedCount = 0
        job?.queued = 0

        // 2. 卡在密码输入上的任务要先放走：continuation 一直挂着，
        //    这个任务永远不会结束，退出就会卡死在「等待收尾」。
        if passwordRequest != nil || activePasswordPrompt != nil || !passwordPromptQueue.isEmpty {
            cancelAllPasswordPrompts()
        }

        // 3. 正在跑的交给 TaskRegistry 终止子进程。这里不能直接退进程：
        //    压缩正在写临时文件、暂存打包正在写 staging 目录，
        //    要等执行体捕获取消、自己把 defer 清理跑完。
        guard let job else {
            notifyWorkDrainedIfNeeded()
            return
        }
        status = "正在取消…"
        TaskRegistry.cancel(job.id)
    }

    func resumeAfterAbortedTermination() {
        isTerminating = false
    }

    func closeWindow() {
        guard !windowClosed else { return }
        windowClosed = true
        routeOpen = nil
        passwordFromOtherWindows = nil
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        openingArchive = nil
        cancelWindowWork()
        payloads.close()
    }
}
