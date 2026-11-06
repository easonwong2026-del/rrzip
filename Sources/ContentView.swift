// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@main
struct RrzipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ArchiveModel()

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
                .frame(minWidth: 1020, minHeight: 600)
                .onAppear { AppDelegate.model = model }
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
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
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: ArchiveModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    // MARK: - 访达右键「服务」

    /// 用 rrzip 打开
    @objc func openWithRrzip(_ pboard: NSPasteboard, userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard)
        guard let first = urls.first else { return }
        if let archive = urls.first(where: { ArchiveKind.isArchive(ext: $0.pathExtension.lowercased()) }) {
            AppDelegate.model?.open(url: archive)
        } else {
            AppDelegate.model?.open(url: first)
        }
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

    private func readURLs(from pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { ArchiveKind.isArchive(ext: $0.pathExtension.lowercased()) })
        else { return }
        Task { @MainActor in AppDelegate.model?.open(url: url) }
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
}

struct ContentView: View {
    @ObservedObject var model: ArchiveModel
    @StateObject private var hover = HoverCoordinator()
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var stashTargeted = false
    @State private var isDropTarget = false
    /// 左右两栏的显隐，跟 viewMode 一样记住用户上次的选择
    @AppStorage("rrzip.showSidebar") private var showSidebar = true
    @AppStorage("rrzip.showInspector") private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            breadcrumbBar
            Hairline()

            if model.current == nil {
                emptyState
            } else {
                // HSplitView 里条件显隐子视图后，理想宽度会算不准，
                // 必须显式把可用宽高喂给它，否则最右一栏会被窗口裁掉
                GeometryReader { proxy in
                    HSplitView {
                        if showSidebar {
                            sidebar
                                .frame(minWidth: 172, idealWidth: 198, maxWidth: 280)
                        }
                        entryList
                            .frame(minWidth: 360)
                        if showInspector {
                            detailPane
                                .frame(minWidth: 250, idealWidth: 288, maxWidth: 340)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                // GeometryReader 的理想宽度接近 0，会让窗口被挤到最小宽度，补回理想尺寸
                .frame(idealWidth: 1120, idealHeight: 660)
            }

            if model.isStashVisible {
                Hairline()
                stashBar
            }

            Hairline()
            statusBar
        }
        .overlay { dropOverlay }
        .preferredColorScheme(model.appearance.scheme)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            guard !providers.isEmpty else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { value, _ in
                            continuation.resume(returning: value)
                        }
                    }
                    if let url { urls.append(url) }
                }
                if urls.count > 1 {
                    model.batchRequest = BatchRequest(urls: urls, mode: .extract)
                } else if let first = urls.first {
                    model.open(url: first)
                }
            }
            return true
        }
        .task {
#if DEBUG
            // 便于截图/调试：--icons 初始图标视图，--search xxx 预填搜索
            if CommandLine.arguments.contains("--icons") { model.viewMode = .icons }
            if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
                model.searchText = CommandLine.arguments[i + 1]
            }
#endif
            // 调试用：defaults write com.rrzip.mac rrzip.demoMini -bool true
#if DEBUG
            if UserDefaults.standard.bool(forKey: "rrzip.demoMini") {
                MiniPanelController.shared.show()
            }
#endif
#if DEBUG
            // 调试用：defaults write com.rrzip.mac rrzip.batchFiles "a.zip,b.zip"
            if let paths = UserDefaults.standard.string(forKey: "rrzip.batchFiles") {
                let urls = paths.split(separator: ",")
                    .map { URL(fileURLWithPath: String($0)) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                if !urls.isEmpty {
                    let mode: BatchRunner.Mode =
                        UserDefaults.standard.string(forKey: "rrzip.batchMode") == "verify" ? .verify : .extract
                    model.batchRequest = BatchRequest(urls: urls, mode: mode)
                }
            }
#endif
            // 支持 `open -a rrzip xxx.zip` 以及命令行直接传路径
            if model.trail.isEmpty {
                for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
                    let url = URL(fileURLWithPath: arg)
                    if FileManager.default.fileExists(atPath: url.path),
                       ArchiveKind.isArchive(ext: url.pathExtension.lowercased()) {
                        model.open(url: url)
                        break
                    }
                }
            }
            // 调试用：跳进某个包内目录（也支持 defaults write com.rrzip.mac rrzip.goto）
#if DEBUG
            let goto = CommandLine.arguments.firstIndex(of: "--goto").flatMap { index in
                index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
            } ?? UserDefaults.standard.string(forKey: "rrzip.goto")
            if let goto, !goto.isEmpty {
                var waited = 0
                while model.current == nil && waited < 40 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    waited += 1
                }
                model.jump(to: goto)
            }
#endif
            // 调试用：直接弹系统快速查看面板
#if DEBUG
            if UserDefaults.standard.bool(forKey: "rrzip.demoQuickLook") {
                var waited = 0
                while model.displayEntries.isEmpty && waited < 40 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    waited += 1
                }
                if let first = model.displayEntries.first(where: { !$0.isDirectory }) {
                    model.selection = [first.id]
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    QuickLookController.shared.toggle(entry: first, model: model)
                }
            }
#endif
#if DEBUG
            // 调试用：选中指定条目，便于核对右侧预览
            // defaults write com.rrzip.mac rrzip.select "封面.jpg"
            if let wanted = UserDefaults.standard.string(forKey: "rrzip.select"), !wanted.isEmpty {
                var waited = 0
                while model.displayEntries.isEmpty && waited < 40 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    waited += 1
                }
                if let match = model.displayEntries.first(where: { $0.name == wanted })
                    ?? model.displayEntries.first(where: { $0.name.contains(wanted) }) {
                    model.select(match)
                }
            }
#endif
            // 调试用：把前几个文件放进暂存区，便于截图核对
#if DEBUG
            if UserDefaults.standard.bool(forKey: "rrzip.demoStash") {
                var waited = 0
                while model.displayEntries.isEmpty && waited < 40 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    waited += 1
                }
                let targets = model.displayEntries.filter { !$0.isDirectory }.prefix(3)
                model.selection = Set(targets.map(\.id))
                model.addSelectionToStash()
            }
#endif
            // 调试用：--demo-hover 等条目读完弹一次悬停卡片，便于截图核对
#if DEBUG
            if CommandLine.arguments.contains("--demo-hover") || UserDefaults.standard.bool(forKey: "rrzip.demoHover") {
                var waited = 0
                while model.displayEntries.isEmpty && waited < 40 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    waited += 1
                }
                if let first = model.displayEntries.first(where: { !$0.isDirectory }) {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    hover.begin(first, model: model, at: NSPoint(x: 700, y: 620))
                }
            }
#endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .rrzipFocusSearch)) { _ in
            searchFocused = true
        }
        .onAppear {
            // 分栏改成条件显隐后，SwiftUI 算出的理想宽度会小于 defaultSize，
            // 窗口会被挤到最小宽度。首帧把默认尺寸补回来，之后用户怎么拖都不干预。
            // 空状态首帧窗口可能还没 visible，延迟半拍再补
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
                   window.frame.width < 1100 {
                    window.setContentSize(NSSize(width: 1180, height: 720))
                }
            }
        }
        .sheet(item: $model.batchRequest) { request in
            BatchSheet(urls: request.urls, mode: request.mode)
        }
        .alert("出错了", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: 拖入提示

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTarget {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.brand.opacity(0.05))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.brand.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("松开即可打开")
                        .font(TypeScale.bodySmall.weight(.medium))
                }
                .foregroundStyle(Palette.brand)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(8)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 6) {
            ToolButton(symbol: "sidebar.leading",
                       help: showSidebar ? "隐藏目录栏" : "显示目录栏") {
                showSidebar.toggle()
            }

            Button {
                model.openWithPanel()
            } label: {
                Label("打开", systemImage: "folder")
                    .font(TypeScale.bodySmall.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.brand)
            .help("打开压缩包（⌘O）")

            // 解压只留一个入口：有选中解选中、没选中解全部；
            // 旁边的小三角给出明确选项，比两个长得几乎一样的图标好懂
            HStack(spacing: 0) {
                Button {
                    if model.selection.isEmpty { model.extractAll() } else { model.extractSelection() }
                } label: {
                    Label("解压", systemImage: "tray.and.arrow.down")
                        .font(TypeScale.bodySmall.weight(.medium))
                }
                .buttonStyle(.bordered)
                .disabled(model.current == nil)
                .help(model.selection.isEmpty ? "全部解压（⌘E）" : "解压选中的 \(model.selection.count) 项（⇧⌘E）")

                Menu {
                    Button("全部解压") { model.extractAll() }
                        .disabled(model.current == nil)
                    Button("只解压选中项") { model.extractSelection() }
                        .disabled(model.selection.isEmpty)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.current == nil)
                .help("选择解压范围")
            }

            Button {
                model.createArchive()
            } label: {
                Label("新建", systemImage: "archivebox")
                    .font(TypeScale.bodySmall.weight(.medium))
            }
            .buttonStyle(.bordered)
            .help("新建压缩包（⌘N）")

            groupDivider

            ToolButton(symbol: "macwindow.on.rectangle", help: "Mini 小窗：拖入即看，看完就走") {
                MiniPanelController.shared.toggle()
            }
            stashButton

            Spacer(minLength: 12)

            searchField
            viewSwitcher
            ToolButton(symbol: "sidebar.right",
                       help: showInspector ? "隐藏详情栏" : "显示详情栏",
                       inactive: model.current == nil) {
                showInspector.toggle()
            }
            overflowMenu
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.toolbarHeight)
        .background(.bar)
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.6))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    private var stashButton: some View {
        Button {
            model.isStashVisible.toggle()
        } label: {
            Image(systemName: model.stash.isEmpty ? "tray" : "tray.full")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(model.isStashVisible ? Palette.brand : Color.primary.opacity(0.82))
                .frame(width: 27, height: 24)
                .overlay(alignment: .topTrailing) {
                    if !model.stash.isEmpty {
                        Text("\(model.stash.count)")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Palette.brand, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 4, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(model.current == nil)
        .opacity(model.current == nil ? 0.32 : 1)
        .help("暂存区：把选中项攒起来，跨目录跨包一起导出")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索包内文件", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($searchFocused)
                .frame(width: 128)
                .disabled(model.current == nil)
                .onExitCommand { model.searchText = "" }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(searchFocused ? Palette.brand.opacity(0.55) : Color.primary.opacity(0.06),
                              lineWidth: 1)
        )
        .help("搜索包内文件（⌘F）")
    }

    private var viewSwitcher: some View {
        HStack(spacing: 1) {
            ForEach(ArchiveViewMode.allCases) { mode in
                Button {
                    model.viewMode = mode
                } label: {
                    Image(systemName: mode.symbol)
                        .font(TypeScale.label.weight(.medium))
                        .foregroundStyle(model.viewMode == mode ? Color.primary : Color.secondary)
                        .frame(width: 24, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(model.viewMode == mode ? Color.primary.opacity(0.10) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var overflowMenu: some View {
        Menu {
            Button("在访达中显示") { model.revealInFinder() }
            Button("检查完整性") { model.verifyCurrent() }
            if model.isEncrypted { Button("锁定并清除密码") { model.lockCurrent() } }
            Divider()
            Button("添加文件…") { model.addFiles() }
                .disabled(model.isNested)
            Button("删除选中项…") { model.deleteSelection() }
                .disabled(model.selection.isEmpty || model.isNested)
            Divider()
            Picker("外观", selection: $model.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .regular))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .fixedSize()
        .disabled(model.current == nil)
        .opacity(model.current == nil ? 0.35 : 1)
        .help("更多操作")
    }

    // MARK: 面包屑

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            if model.trail.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Text("未打开归档")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            } else if model.isSearching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                    Text("搜索「\(model.searchText)」")
                        .font(TypeScale.bodySmall.weight(.medium))
                    Text("· \(model.displayEntries.count) 个结果")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            } else {
                if model.canGoBack {
                    Button {
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("返回上一级（⌘[）")
                    .padding(.trailing, 2)
                }

                ForEach(Array(model.trail.enumerated()), id: \.element.id) { index, frame in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                    crumb(index: index, frame: frame)
                }
            }

            Spacer(minLength: 8)

            if let current = model.current {
                Text(current.archive.deletingLastPathComponent().path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(current.archive.path)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.breadcrumbHeight)
        .background(.bar.opacity(0.6))
    }

    private func crumb(index: Int, frame: ArchiveModel.Frame) -> some View {
        let isLast = index == model.trail.count - 1
        return Button {
            model.popTo(index)
        } label: {
            HStack(spacing: 5) {
                KindBadge(kind: frame.prefix.isEmpty ? .archive : .folder, side: 15, corner: 4)
                Text(frame.title)
                    .font(TypeScale.bodySmall.weight(isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isLast ? Color.primary.opacity(0.055) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(frame.title)
    }

    // MARK: 目录树

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("目录")
                    .font(TypeScale.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.folderTree.count > 0 {
                    Text("\(model.folderTree.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    SidebarRow(
                        title: model.current?.archive.deletingPathExtension().lastPathComponent ?? "根目录",
                        kind: .archive,
                        isSelected: model.current?.prefix.isEmpty == true
                    ) {
                        model.jump(to: "")
                    }

                    OutlineGroup(model.folderTree, children: \.optionalChildren) { node in
                        SidebarRow(
                            title: node.name,
                            kind: .folder,
                            isSelected: model.current?.prefix == node.path
                        ) {
                            model.jump(to: node.path)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    // MARK: 详情

    private var detailKind: FileKind {
        guard let ext = model.current?.archive.pathExtension.lowercased() else { return .archive }
        return FileKind(ext: ext)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            detailHeader
            infoCard
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            Hairline()
            PreviewPane(model: model)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var detailHeader: some View {
        let kind = detailKind
        return VStack(spacing: 7) {
            KindBadge(kind: kind, side: 44, corner: 11)
            Text(model.current?.archive.lastPathComponent ?? "")
                .font(TypeScale.title)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
            HStack(spacing: 5) {
                TintPill(text: model.archiveFormatName, tint: kind.tint)
                if model.isEncrypted {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill").font(.system(size: 7.5, weight: .bold))
                        Text("已加密").font(.system(size: 9.5, weight: .semibold))
                    }
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            LinearGradient(colors: [kind.tint.opacity(0.07), kind.tint.opacity(0.015)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("大小", model.archiveSizeText)
            rowDivider
            infoRow("条目", "\(model.totalEntryCount)")
            rowDivider
            infoRow("加密", model.isEncrypted ? "是" : "否")
            rowDivider
            infoRow("修改", model.archiveModifiedText)
            rowDivider
            infoRow("识别", model.detectionSourceText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .cardSurface()
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(height: 1)
            .padding(.leading, 2)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(TypeScale.data())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4.5)
    }

    // MARK: 条目区

    private var entryList: some View {
        VStack(spacing: 0) {
            if model.viewMode == .list {
                listHeader
            }

            if model.displayEntries.isEmpty {
                emptyFolder
            } else if model.viewMode == .icons {
                iconGrid
            } else if model.viewMode == .columns && !model.isSearching {
                columnsView
            } else {
                listView
            }

            if !model.selection.isEmpty {
                flowBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            model.activateSelected()
            return .handled
        }
        .onKeyPress(.space) {
            QuickLookController.shared.toggle(entry: model.selectedEntry, model: model)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.goBack()
            return .handled
        }
        .onKeyPress(KeyEquivalent("a"), phases: .down) { press in
            guard press.modifiers.contains(EventModifiers.command) else { return .ignored }
            model.selectAll()
            return .handled
        }
        .onKeyPress(.escape) {
            if !model.searchText.isEmpty {
                model.searchText = ""
                return .handled
            }
            if !model.selection.isEmpty {
                model.selection = []
                return .handled
            }
            return .ignored
        }
        .onAppear { listFocused = true }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("名称")
                .padding(.leading, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("大小")
                .frame(width: Metrics.sizeColumn, alignment: .trailing)
            Text("修改时间")
                .frame(width: Metrics.dateColumn, alignment: .trailing)
        }
        .font(TypeScale.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var emptyFolder: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isSearching ? "magnifyingglass" : "folder")
                .font(.system(size: 24, weight: .thin))
                .foregroundStyle(.quaternary)
            Text(model.isSearching ? "没有匹配的文件" : "这个目录是空的")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if model.isSearching && !model.searchText.isEmpty {
                Button("清除搜索") { model.searchText = "" }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.displayEntries) { entry in
                        EntryRow(
                            entry: entry,
                            model: model,
                            hover: hover,
                            selected: model.selection.contains(entry.id),
                            showPath: model.isSearching
                        )
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { _, selection in
                // 键盘上下移动时要跟着滚动，否则选中项跑出屏幕就看不见了
                guard let id = selection.first else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// 分栏视图：每列一层目录，点目录在右侧开新列（类似访达的列视图）
    private var columnsView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(model.trail.enumerated()), id: \.element.id) { index, frame in
                        columnView(frame: frame, isLast: index == model.trail.count - 1)
                            .frame(width: 224)
                            .id(index)
                        Hairline(vertical: true)
                    }
                }
            }
            // 窗口不宽时新列会落在可视区外，看起来像「点了没反应」，必须跟到最新一列
            .onChange(of: model.trail.count) { _, count in
                guard count > 0 else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(count - 1, anchor: .trailing)
                }
            }
            .onAppear {
                guard model.trail.count > 1 else { return }
                proxy.scrollTo(model.trail.count - 1, anchor: .trailing)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func columnView(frame: ArchiveModel.Frame, isLast: Bool) -> some View {
        let items = model.entries(at: frame.prefix)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(frame.prefix.isEmpty
                     ? (model.current?.archive.deletingPathExtension().lastPathComponent ?? "根目录")
                     : frame.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                if items.isEmpty {
                    Text("空目录")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(10)
                }

                ForEach(items) { entry in
                    let selected = model.selection.contains(entry.id)
                    ColumnRow(entry: entry, model: model, hover: hover, selected: selected)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6)], spacing: 6) {
                ForEach(model.displayEntries) { entry in
                    IconTile(
                        entry: entry,
                        model: model,
                        hover: hover,
                        selected: model.selection.contains(entry.id)
                    )
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// 选中后浮出的快捷操作条
    private var flowBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.brand)
                Text("已选 \(model.selection.count) 项")
                    .font(TypeScale.label.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Palette.brand.opacity(0.10), in: Capsule())

            Spacer()

            Button("解压到文件夹…") { model.extractSelection() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if let entry = model.displayEntries.first(where: { model.selection.contains($0.id) }),
               !entry.isDirectory {
                Button("另存为…") { exportSelected() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button("暂存") { model.addSelectionToStash() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("删除…") { model.deleteSelection() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            ToolButton(symbol: "xmark", help: "取消选择（Esc）") { model.selection = [] }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
    }

    private func exportSelected() {
        guard let entry = model.displayEntries.first(where: { model.selection.contains($0.id) }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.payloadURL(for: entry) { url in
            guard let url else { return }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: url, to: destination)
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Palette.brand.opacity(0.18), Palette.brand.opacity(0.04)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 82, height: 82)
                    Image(systemName: "shippingbox")
                        .font(.system(size: 33, weight: .light))
                        .foregroundStyle(Palette.brand)
                }

                VStack(spacing: 5) {
                    Text("把压缩包拖进来")
                        .font(TypeScale.display)
                    Text("也可以 ⌘O 选择文件，或从访达右键「用 rrzip 打开」")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    ForEach(["ZIP", "7Z", "RAR", "TAR", "GZ", "ISO", "DMG"], id: \.self) { name in
                        Text(name)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .foregroundStyle(.secondary)
                    }
                }

                Button("选择压缩包…") { model.openWithPanel() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.brand)
                    .controlSize(.large)
                    .padding(.top, 2)

                Text("加密包会提示输入密码")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.brand.opacity(0.16),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            )
            .frame(maxWidth: 420)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: 暂存区

    private var stashBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "tray.full")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("暂存区")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(model.stash.count) 项")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("打包成 ZIP") { model.compressStash() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("全部导出…") { model.exportStash() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("清空") { model.clearStash() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    model.isStashVisible = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("收起暂存区")
            }
            .padding(.horizontal, 14)
            .padding(.top, 7)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if model.stash.isEmpty {
                        Text("把文件拖到这里暂存，最后一起导出")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 2)
                    }
                    ForEach(model.stash) { item in
                        HStack(spacing: 5) {
                            KindBadge(kind: FileKind(ext: (item.path as NSString).pathExtension.lowercased()),
                                      side: 14, corner: 3)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name)
                                    .font(.system(size: 10.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(item.displaySize)
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                model.removeFromStash(item)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.5)
                        )
                        .help(item.path)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
        }
        .background(.bar)
        .overlay(alignment: .top) {
            if stashTargeted {
                Rectangle()
                    .fill(Palette.brand.opacity(0.55))
                    .frame(height: 2)
            }
        }
        .onDrop(of: [rrzipEntryType], isTargeted: $stashTargeted) { providers in
            for provider in providers {
                _ = provider.loadDataRepresentation(forTypeIdentifier: rrzipEntryType.identifier) { data, _ in
                    guard let data,
                          let text = String(data: data, encoding: .utf8) else { return }
                    let parts = text.components(separatedBy: "\u{1F}")
                    guard parts.count == 3 else { return }
                    let archive = URL(fileURLWithPath: parts[0])
                    let path = parts[1]
                    let size = Int64(parts[2]) ?? 0
                    Task { @MainActor in
                        model.addToStash(archive: archive, path: path, size: size)
                    }
                }
            }
            return true
        }
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 7) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Palette.brand)
            } else {
                Circle()
                    .fill(Palette.brand)
                    .frame(width: 5, height: 5)
            }

            Text(model.status)
                .font(TypeScale.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if model.isSearching {
                statusItem("\(model.displayEntries.count) 个结果")
                if !model.selection.isEmpty { statusDot }
            }
            if !model.selection.isEmpty {
                Text("已选 \(model.selection.count) 项")
                    .font(TypeScale.caption.weight(.medium))
                    .foregroundStyle(Palette.brand)
                statusDot
            }
            if !model.archiveSizeText.isEmpty {
                if !model.isSearching || !model.selection.isEmpty { statusDot }
                statusItem(model.archiveSizeText, mono: true)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.statusHeight)
        .background(.bar)
    }

    private var statusDot: some View {
        Circle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 2.5, height: 2.5)
    }

    private func statusItem(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? TypeScale.data(10.5) : TypeScale.caption)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - 列表行

private struct EntryRow: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    @ObservedObject var hover: HoverCoordinator
    let selected: Bool
    let showPath: Bool

    @State private var hovering = false

    private var rowHeight: CGFloat {
        showPath ? Metrics.rowHeightWide : Metrics.rowHeight
    }

    var body: some View {
        HStack(spacing: 8) {
            EntryThumbnail(entry: entry, model: model, side: 20, corner: 4)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(TypeScale.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showPath {
                    Text(entry.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if entry.isArchive && !entry.isDirectory {
                TintPill(text: "嵌套", tint: FileKind.archive.tint)
            }

            Spacer(minLength: 8)

            Text(entry.isDirectory ? "—" : entry.displaySize)
                .font(TypeScale.data())
                .foregroundStyle(.secondary)
                .frame(width: Metrics.sizeColumn, alignment: .trailing)

            Text(entry.modified)
                .font(TypeScale.data())
                .foregroundStyle(.tertiary)
                .frame(width: Metrics.dateColumn, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(selected
                      ? Palette.brand.opacity(Palette.selectionFill)
                      : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .strokeBorder(selected ? Palette.brand.opacity(Palette.selectionStroke) : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.activate(entry) }
        .onTapGesture { model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
        .onDrag { EntryDrag.provider(for: entry, model: model) }
        .onHover { inside in
            hovering = inside
            if inside { hover.begin(entry, model: model) } else { hover.end() }
        }
        .contextMenu {
            Button(entry.isDirectory ? "进入文件夹" : "打开") { model.activate(entry) }
                .disabled(!entry.isDirectory && !entry.isArchive)
            Button("解压到…") {
                model.selection = [entry.id]
                model.extractSelection()
            }
            Button("另存为…") {
                model.selection = [entry.id]
                exportSingle(entry)
            }
            .disabled(entry.isDirectory)
            Divider()
            Button("加入暂存区") {
                model.selection = [entry.id]
                model.addSelectionToStash()
            }
            .disabled(entry.isDirectory)
            Button("加入文件…") { model.addFiles() }
                .disabled(model.isNested)
            Button("从压缩包删除…") {
                model.selection = [entry.id]
                model.deleteSelection()
            }
            .foregroundStyle(.red)
            .disabled(model.isNested)
        }
        .help(entry.path)
    }

    private func exportSingle(_ entry: ArchiveEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.payloadURL(for: entry) { url in
            guard let url else { return }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: url, to: destination)
        }
    }
}

// MARK: - 分栏行

private struct ColumnRow: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    @ObservedObject var hover: HoverCoordinator
    let selected: Bool

    @State private var hovering = false

    var body: some View {
        // 目录只在单击时跳转（等价访达列视图：在右侧开下一列）。
        // 不能再挂双击 activate——单击已经 jump 过一次，双击会再 push 一层，
        // 面包屑出现「照片 › 照片」，看起来就像套了一层。
        if entry.isDirectory {
            row
                .onTapGesture { model.jump(to: entry.path) }
        } else {
            row
                .onTapGesture(count: 2) { model.activate(entry) }
                .onTapGesture { model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            EntryThumbnail(entry: entry, model: model, side: 16, corner: 3)
                .frame(width: 16, height: 16)
            Text(entry.name)
                .font(TypeScale.bodySmall)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected
                      ? Palette.brand.opacity(Palette.selectionFill)
                      : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onDrag { EntryDrag.provider(for: entry, model: model) }
        .onHover { inside in
            hovering = inside
            if inside { hover.begin(entry, model: model) } else { hover.end() }
        }
        .help(entry.path)
    }
}

// MARK: - 图标网格

private struct IconTile: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    @ObservedObject var hover: HoverCoordinator
    let selected: Bool

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            EntryThumbnail(entry: entry, model: model, side: 64, corner: 10)
                .frame(width: 64, height: 64)

            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(height: 27, alignment: .top)

            Text(entry.isDirectory ? "文件夹" : entry.displaySize)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected
                      ? Palette.brand.opacity(Palette.selectionFill)
                      : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Palette.brand.opacity(Palette.selectionStroke) : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.activate(entry) }
        .onTapGesture { model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
        .onDrag { EntryDrag.provider(for: entry, model: model) }
        .onHover { inside in
            hovering = inside
            if inside { hover.begin(entry, model: model) } else { hover.end() }
        }
        .help(entry.path)
    }
}

// MARK: - 侧栏行

private struct SidebarRow: View {
    let title: String
    let kind: FileKind
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                KindBadge(kind: kind, side: 16, corner: 4)
                Text(title)
                    .font(TypeScale.bodySmall.weight(isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected
                          ? Palette.brand.opacity(Palette.selectionFill)
                          : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}
