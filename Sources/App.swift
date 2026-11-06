// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  应用入口与 AppDelegate：打开请求、服务、通知授权、窗口尺寸。

import AppKit
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
// UNUserNotificationCenter 没标 Sendable，但它的方法本身就是线程安全的；
// 用 @preconcurrency 压掉严格并发下的误报，不绕过检查本身
@preconcurrency import UserNotifications

@main
struct RrzipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject var model = ArchiveModel()

    init() {
        // 有命令行参数就按 CLI 跑完退出，否则进入正常界面
        if let code = Self.runCLI() { exit(code) }
    }

    /// 命令行入口：返回退出码，nil 表示没有 CLI 参数。
    /// 这里刻意不用返回 Never 的局部函数——CI 的 Swift 6.0 在 -O 下会把它优化成
    /// 不执行，导致 --list 走到「读取失败」分支。
    private static func runCLI() -> Int32? {
        let args = CommandLine.arguments

        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }

        func writeError(_ message: String) {
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        }

        let password = value("--pass")

        // 精确识别：便于排查「后缀不对但内容对」的文件
        if let path = value("--detect") {
            let url = URL(fileURLWithPath: path)
            guard let detection = FormatDetector.detect(url) else {
                writeError("无法识别 \(url.lastPathComponent)")
                return 1
            }
            print("\(detection.format.id)\t\(detection.displayName)\t\(detection.source.rawValue)")
            print("openable=\(detection.format.isOpenable)\tsevenZip=\(detection.format.sevenZipType ?? "-")")
            return 0
        }

        // 位置参数 = 指定选项之后、到下一个选项之前的所有值
        func positional(after flag: String) -> [String] {
            guard let start = args.firstIndex(of: flag) else { return [] }
            let takesValue: Set<String> = ["--prefix", "--pass"]
            var out: [String] = []
            var index = start + 1
            while index < args.count {
                let token = args[index]
                if takesValue.contains(token) { index += 2; continue }
                if token.hasPrefix("--") { break }
                out.append(token)
                index += 1
            }
            return out
        }

        if args.contains("--add") {
            let list = positional(after: "--add")
            guard let first = list.first else {
                writeError("--add 需要一个归档路径")
                return 1
            }
            let items = list.dropFirst().map { URL(fileURLWithPath: $0) }
            guard !items.isEmpty else {
                writeError("--add 需要至少一个待加入的文件")
                return 1
            }
            do {
                try SevenZip.add(URL(fileURLWithPath: first), items: Array(items),
                                 prefix: value("--prefix") ?? "", password: password)
                print("added \(items.count)")
                return 0
            } catch {
                writeError(error.localizedDescription)
                return 1
            }
        }

        if args.contains("--remove") {
            let list = positional(after: "--remove")
            guard let first = list.first else {
                writeError("--remove 需要一个归档路径")
                return 1
            }
            do {
                try SevenZip.remove(URL(fileURLWithPath: first), entries: Array(list.dropFirst()), password: password)
                print("removed \(list.count - 1)")
                return 0
            } catch {
                writeError(error.localizedDescription)
                return 1
            }
        }

        // 渲染缩略图到 PNG：rrzip --thumb <归档> <包内路径> <输出.png> [--size 560]
        if args.contains("--thumb") {
            let rest = positional(after: "--thumb")
            guard rest.count >= 3 else {
                writeError("用法：--thumb <归档> <包内路径> <输出.png>")
                return 1
            }
            let archive = URL(fileURLWithPath: rest[0])
            let entryPath = rest[1]
            let output = URL(fileURLWithPath: rest[2])
            let side = Double(value("--size") ?? "560") ?? 560
            let ext = (entryPath as NSString).pathExtension.lowercased()

            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("rrzip-thumb-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            do {
                try SevenZip.extract(archive, entries: [entryPath], to: staging, password: password)
            } catch {
                writeError(error.localizedDescription)
                return 1
            }
            let file = staging.appendingPathComponent(entryPath)
            guard let image = ThumbnailStore.renderForTool(url: file, ext: ext, maxPixel: side) else {
                writeError("渲染失败 \(entryPath)")
                return 1
            }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                writeError("编码失败")
                return 1
            }
            do {
                try data.write(to: output)
                print("ok \(image.width)x\(image.height) -> \(output.path)")
                return 0
            } catch {
                writeError(error.localizedDescription)
                return 1
            }
        }

        guard let path = value("--list") else { return nil }
        let url = URL(fileURLWithPath: path)

        // 按识别结果决定先试哪个引擎，失败再换另一个
        let order: [ArchiveEngine] = FormatDetector.prefersSevenZip(url)
            ? [.sevenZip, .libarchive] : [.libarchive, .sevenZip]

        var listed: [ArchiveEntry]?
        var lastError: Error?
        for engine in order {
            do {
                switch engine {
                case .libarchive: listed = try Tar.list(url, passphrase: password)
                case .sevenZip: listed = try SevenZip.list(url, password: password)
                }
                break
            } catch {
                lastError = error
            }
        }

        guard let entries = listed else {
            writeError(lastError?.localizedDescription ?? "读取失败")
            return 1
        }
        for entry in entries {
            print("\(entry.mode)\t\(entry.size)\t\(entry.modified)\t\(entry.path)")
        }
        return 0
    }

    var body: some Scene {
        Window("rrzip", id: "main") {
            ContentView(model: model)
                // 最小尺寸与模式无关：简化与完整共用同一个下限，
                // 否则窗口永远缩不进触发自动收起的宽度
                .frame(minWidth: Layout.minWindowWidth, minHeight: Layout.minWindowHeight)
                .onAppear { AppDelegate.attach(model) }
        }
        .defaultSize(width: 720, height: 520)
        .commands {            CommandGroup(replacing: .newItem) {
                Button("打开压缩包…") { model.openWithPanel() }
                    .keyboardShortcut("o")
                Button("新建压缩包…") { model.createArchive() }
                    .keyboardShortcut("n")
                Divider()
                Button("全部解压…") { model.extractAll() }
                    .keyboardShortcut("e")
                Button("解压选中项…") { model.extractSelection() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("返回上一级") {
                    if model.canGoBack { model.popTo(model.trail.count - 2) }
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            }
        }
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("搜索包内文件") {
                    NotificationCenter.default.post(name: .rrzipFocusSearch, object: nil)
                }
                .keyboardShortcut("f")
            }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("返回上级") { model.goBack() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoBack)
                Button("快速查看") {
                    QuickLookController.shared.toggle(entry: model.selectedEntry, model: model)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selectedEntry == nil)
                Button("加入暂存区") { model.addSelectionToStash() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("批量处理…") { model.pickBatch() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("检查当前压缩包") { model.verifyCurrent() }
                    .disabled(model.current == nil)
                Divider()
                Button(model.isCompactMode ? "展开为完整模式" : "收起为简化模式") {
                    NotificationCenter.default.post(name: .rrzipToggleWorkspaceMode, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .control])
            }
            // 帮助菜单里随时能重看首次启动那一屏
            CommandGroup(replacing: .help) {
                Button("欢迎使用 rrzip") {
                    NotificationCenter.default.post(name: .rrzipShowWelcome, object: nil)
                }
            }
        }

        // 设置中心：⌘, 由系统菜单自动提供
        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: ArchiveModel?

    /// 冷启动时收到的文件。此时窗口还没建好、`model` 仍是 nil，
    /// 直接调 `.open` 会被可选链吞掉——表现就是「右键用 rrzip 打开，毫无反应」。
    /// 先存下来，等 ContentView 上屏后由 `attach` 取走。
    @MainActor private(set) static var pendingOpen: [URL] = []

    /// ContentView 上屏时调用：接上 model，并把冷启动排队中的文件放进去
    @MainActor
    static func attach(_ model: ArchiveModel) {
        Self.model = model
        // 访达那边转交过来的结果（跳过 N 个、解压失败），启动时补一句
        if let notice = PendingNotice.take() {
            model.notice = "\(notice.title) · \(notice.message)"
        }
        guard !pendingOpen.isEmpty else { return }
        let urls = pendingOpen
        pendingOpen = []
        open(urls)
    }

    /// 所有「从外部打开」的入口都走这里：能判定就直接开，判不了就告知
    @MainActor
    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let model else {
            pendingOpen = urls
            return
        }
        let archives = urls.filter {
            if case .open = OpenGate.decide($0) { return true }
            return false
        }
        if let first = archives.first {
            model.open(url: first)
            if archives.count > 1 {
                model.notice = "另有 \(archives.count - 1) 个压缩包未打开"
            }
        } else if let first = urls.first {
            // 交回 model 走 unrecognized 分支，给出真实提示而不是静默返回
            model.open(url: first)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        requestNotificationPermissionIfNeeded()
    }

    /// 访达那边做完任务后只是「唤起 app」，不带文件参数，
    /// `application(_:open:)` 不会触发。激活时才取结果最稳。
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            guard let notice = PendingNotice.take(), let model = AppDelegate.model else { return }
            model.notice = "\(notice.title) · \(notice.message)"
        }
    }

    /// 访达扩展只能投递通知、不能申请授权，所以授权这件事只能由主程序做。
    /// 晚 2.5 秒，避开首帧窗口与首次引导。
    func requestNotificationPermissionIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else { return }
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    // MARK: - 访达右键「服务」

    /// 用 rrzip 打开
    @objc func openWithRrzip(_ pboard: NSPasteboard, userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard)
        guard !urls.isEmpty else { return }
        // 与 application(_:open:) 同一条判定，不在这里另设后缀白名单
        AppDelegate.open(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 用 rrzip 压缩：在源文件旁边生成同名 zip
    @objc func compressWithRrzip(_ pboard: NSPasteboard, userData: String,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard)
        guard !urls.isEmpty else { return }

        let base = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "归档"
        let folder = urls[0].deletingLastPathComponent()
        var output = folder.appendingPathComponent("\(base).zip")
        var index = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = folder.appendingPathComponent("\(base) \(index).zip")
            index += 1
        }

        do {
            try Tar.create(at: output, from: urls, format: "zip")
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            let alert = NSAlert()
            alert.messageText = "压缩失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// 用 rrzip 解压到此处：每个包解到它自己所在的目录
    @objc func extractHereWithRrzip(_ pboard: NSPasteboard, userData: String,
                                    error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard).filter { ArchiveService.canOpen($0) }
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            var failed: [String] = []
            for url in urls {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ArchiveService.extract(url, entries: [],
                                                   to: url.deletingLastPathComponent(),
                                                   password: nil)
                    }.value
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            if failed.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(
                    urls.map { $0.deletingLastPathComponent() }
                )
            } else {
                let alert = NSAlert()
                alert.messageText = "有 \(failed.count) 个包没能解压"
                alert.informativeText = failed.joined(separator: "\n")
                    + "\n\n加密包需要密码，请用 rrzip 打开后解压。"
                alert.runModal()
            }
        }
    }

    /// 用 rrzip 分别压缩：每个文件各生成一个 zip，不合并
    @objc func compressEachWithRrzip(_ pboard: NSPasteboard, userData: String,
                                     error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            var made: [URL] = []
            for url in urls {
                let folder = url.deletingLastPathComponent()
                let name = url.deletingPathExtension().lastPathComponent
                let output = ArchiveModel.uniqueOutput(
                    folder.appendingPathComponent(name).appendingPathExtension("zip")
                )
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Tar.create(at: output, from: [url], format: "zip")
                    }.value
                    made.append(output)
                } catch {
                    // 单个失败不影响其他文件
                }
            }
            if !made.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(made)
            }
        }
    }

    func readURLs(from pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            AppDelegate.open(urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 窗口关掉后再点 Dock 图标，把主窗口找回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

// MARK: - 主界面

extension Notification.Name {
    /// ⌘F：把焦点丢进搜索框（菜单项发、主界面收）
    static let rrzipFocusSearch = Notification.Name("rrzipFocusSearch")
    /// ⌃⌘M：简化 / 完整模式互切（菜单项发、主界面收，窗口尺寸由主界面负责）
    static let rrzipToggleWorkspaceMode = Notification.Name("rrzipToggleWorkspaceMode")
    /// 帮助菜单：随时重看首次启动那一屏
    static let rrzipShowWelcome = Notification.Name("rrzipShowWelcome")
}
