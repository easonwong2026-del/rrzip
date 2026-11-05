// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Combine
import Foundation

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

/// 暂存区里的一条：记住它来自哪个包，才能跨层、跨包累积
struct StashItem: Identifiable, Hashable {
    let id = UUID()
    let archive: URL
    let path: String
    let size: Int64
    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }
    var displaySize: String { ByteFormatter.string(size) }
}

struct CreateOptions {
    var format: CreateFormat = .zip
    var password: String = ""
    var volume: CreateVolume = .none
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
    @Published var viewMode: ArchiveViewMode = .list
    /// 每次重新点同一行就自增，强制预览刷新
    @Published private(set) var previewToken: Int = 0
    @Published private(set) var isLoading = false
    @Published var status: String = "拖入一个压缩包，或按 ⌘O 打开"
    @Published var errorMessage: String?
    @Published private(set) var unlocked: Set<String> = []
    /// 暂存区：跨层、跨包攒起来，最后一次性导出
    @Published private(set) var stash: [StashItem] = []
    @Published var isStashVisible = false

    var current: Frame? { trail.last }
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
            return cachedFrame()?.childIndex[frame.prefix] ?? []
        }
        if let cached = searchCache, cached.frameID == frame.id, cached.keyword == keyword {
            return cached.result
        }
        let result = frame.entries
            .filter { $0.path.localizedCaseInsensitiveContains(keyword) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        searchCache = (frame.id, keyword, result)
        return result
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
        guard let frame = current,
              let attrs = try? FileManager.default.attributesOfItem(atPath: frame.archive.path),
              let date = attrs[.modificationDate] as? Date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy 年 M 月 d 日 HH:mm"
        return formatter.string(from: date)
    }

    /// 当前归档的大小，显示在状态栏
    var archiveSizeText: String {
        guard let frame = current,
              let attrs = try? FileManager.default.attributesOfItem(atPath: frame.archive.path),
              let size = attrs[.size] as? Int64 else { return "" }
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

    /// 单击：选中并刷新预览
    func select(_ entry: ArchiveEntry) {
        if selection == [entry.id] {
            previewToken &+= 1      // 重复点同一条也要重新加载
        } else {
            selection = [entry.id]
        }
    }

    /// 双击：目录进入下一层，嵌套包展开，其余不动
    func activate(_ entry: ArchiveEntry) {
        if entry.isDirectory {
            pushFolder(entry)
        } else if entry.isArchive {
            enter(entry)
        }
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
        if let keyword = UserDefaults.standard.string(forKey: "rrzip.search") {
            searchText = keyword
        }
    }
    /// 预览/导出缓存：key = 归档路径 + 修改时间 + 条目路径
    private var payloadCache: [String: URL] = [:]

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

    // MARK: - 打开

    func open(url: URL) {
        guard ArchiveKind.isArchive(ext: url.pathExtension.lowercased()) else {
            errorMessage = "不支持的格式：.\(url.pathExtension)"
            return
        }
        loadFrame(url: url, resetTrail: true)
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择要打开的压缩包"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    private func loadFrame(url: URL, resetTrail: Bool, restorePrefix: String? = nil) {
        isLoading = true
        status = "正在读取 \(url.lastPathComponent)…"
        Task { await performLoad(url: url, resetTrail: resetTrail, restorePrefix: restorePrefix) }
    }

    private func performLoad(url: URL, resetTrail: Bool, restorePrefix: String? = nil) async {
        var passphrase = passwords[url.path]
        let detection = FormatDetector.detect(url)
        // 磁盘映像类（dmg/vhd/qcow2…）libarchive 读不了，直接交给 7-Zip
        var engine: ArchiveEngine = FormatDetector.prefersSevenZip(url) ? .sevenZip : .libarchive
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
        let frame = Frame(archive: url, entries: entries, engine: engine, detection: detection)
        if resetTrail { trail = [frame] } else { trail.append(frame) }
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

    func removeFromStash(_ item: StashItem) {
        stash.removeAll { $0.id == item.id }
    }

    func clearStash() {
        stash.removeAll()
        isStashVisible = false
    }

    /// 把暂存项全部解压到用户选的目录
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
        isLoading = true
        status = "正在导出 \(items.count) 项…"
        Task {
            var failed = 0
            for item in items {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try SevenZip.extract(item.archive, entries: [item.path],
                                             to: destination, password: passwordMap[item.archive.path])
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
                    try SevenZip.extract(item.archive, entries: [item.path],
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
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: output)
                    try SevenZip.create(at: output, from: files, format: "zip", password: nil, volume: nil)
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

    /// 返回上一级（Mini 窗口的返回键）
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

    func extractAll() {
        guard let frame = current else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到此处"
        panel.message = "选择解压目标文件夹"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        extract(entries: [], from: frame, to: destination)
    }

    func extractSelection() {
        guard let frame = current else { return }
        let chosen = entries.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到此处"
        panel.message = "解压选中的 \(chosen.count) 个项目"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
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
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
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
                if payloadCache.count > 300 { payloadCache.removeAll() }
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
        let needsSevenZip = options.format.usesSevenZip || !options.password.isEmpty || volume != nil

        // 覆盖写：7zz 的 a 命令对已存在的包是「追加」而不是重建，先删干净
        try? FileManager.default.removeItem(at: output)
        if volume != nil {
            let folder = output.deletingLastPathComponent()
            let prefix = output.lastPathComponent + "."
            if let siblings = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for sibling in siblings where sibling.lastPathComponent.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(at: sibling)
                }
            }
        }

        Task {
            do {
                if needsSevenZip {
                    guard SevenZip.isAvailable else { throw ArchiveError.engineUnavailable }
                    try await Task.detached {
                        try SevenZip.create(
                            at: output,
                            from: items,
                            format: options.format == .sevenZip ? "7z" : options.format.ext,
                            password: options.password.isEmpty ? nil : options.password,
                            volume: volume
                        )
                    }.value
                } else {
                    try await Task.detached {
                        try Tar.create(at: output, from: items, format: options.format.ext)
                    }.value
                }
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
