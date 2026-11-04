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
        var title: String { archive.deletingPathExtension().lastPathComponent }
    }

    @Published private(set) var trail: [Frame] = []
    @Published var selection: Set<ArchiveEntry.ID> = []
    @Published private(set) var isLoading = false
    @Published var status: String = "拖入一个压缩包，或按 ⌘O 打开"
    @Published var errorMessage: String?
    @Published private(set) var unlocked: Set<String> = []

    var current: Frame? { trail.last }
    var entries: [ArchiveEntry] { current?.entries ?? [] }
    var canGoBack: Bool { trail.count > 1 }
    var isEncrypted: Bool { current.map { unlocked.contains($0.archive.path) } ?? false }

    private var passwords: [String: String] = [:]
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

    private func loadFrame(url: URL, resetTrail: Bool) {
        isLoading = true
        status = "正在读取 \(url.lastPathComponent)…"
        Task { await performLoad(url: url, resetTrail: resetTrail) }
    }

    private func performLoad(url: URL, resetTrail: Bool) async {
        var passphrase = passwords[url.path]
        var engine: ArchiveEngine = .libarchive
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
        let frame = Frame(archive: url, entries: entries, engine: engine)
        if resetTrail { trail = [frame] } else { trail.append(frame) }
        selection = []
        status = "\(entries.count) 个项目 · \(url.lastPathComponent)"
        isLoading = false
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
        guard save.runModal() == .OK, var output = save.url else { return }
        if output.pathExtension.lowercased() != options.format.ext {
            output = output.deletingPathExtension().appendingPathExtension(options.format.ext)
        }

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
