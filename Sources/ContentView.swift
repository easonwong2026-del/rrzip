import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@main
struct RrzipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ArchiveModel()

    init() { Self.handleCLI() }

    /// 便于在终端里验证解析结果：rrzip --list <压缩包> [--pass 密码]
    private static func handleCLI() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--list"), flag + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[flag + 1])
        let password: String? = {
            guard let index = args.firstIndex(of: "--pass"), index + 1 < args.count else { return nil }
            return args[index + 1]
        }()

        func dump(_ entries: [ArchiveEntry]) {
            for entry in entries {
                print("\(entry.mode)\t\(entry.size)\t\(entry.modified)\t\(entry.path)")
            }
            exit(0)
        }
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            exit(1)
        }

        do {
            dump(try Tar.list(url, passphrase: password))
        } catch ArchiveError.needsPassword {
            do { dump(try SevenZip.list(url, password: password)) }
            catch { fail(error.localizedDescription) }
        } catch {
            let message = error.localizedDescription
            if message.lowercased().contains("header is encrypted") {
                do { dump(try SevenZip.list(url, password: password)) }
                catch { fail(error.localizedDescription) }
            }
            fail(message)
        }
    }

    var body: some Scene {
        WindowGroup("rrzip") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { AppDelegate.model = model }
        }
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
}

struct ContentView: View {
    @ObservedObject var model: ArchiveModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            breadcrumb
            Divider()

            if model.current == nil {
                emptyState
            } else {
                HSplitView {
                    entryList
                        .frame(minWidth: 520)
                    PreviewPane(model: model)
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                }
            }

            Divider()
            statusBar
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.open(url: url) }
            }
            return true
        }
        .task {
            // 便于截图/调试：--icons 初始图标视图，--search xxx 预填搜索
            if CommandLine.arguments.contains("--icons") { model.viewMode = .icons }
            if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
                model.searchText = CommandLine.arguments[i + 1]
            }
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

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.openWithPanel()
            } label: {
                Label("打开", systemImage: "folder")
            }

            Button {
                model.extractAll()
            } label: {
                Label("全部解压", systemImage: "arrow.down.doc")
            }
            .disabled(model.current == nil)

            Button {
                model.extractSelection()
            } label: {
                Label("解压选中", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(model.selection.isEmpty)

            Divider().frame(height: 18)

            Button {
                model.createArchive()
            } label: {
                Label("新建", systemImage: "archivebox")
            }

            Spacer(minLength: 12)

            searchField

            Picker("视图", selection: $model.viewMode) {
                ForEach(ArchiveViewMode.allCases) { mode in
                    Image(systemName: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)
            .help("切换列表 / 图标")

            if model.isLoading { ProgressView().controlSize(.small) }

            Menu {
                Button("在访达中显示") { model.revealInFinder() }
                if model.isEncrypted { Button("锁定并清除密码") { model.lockCurrent() } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.current == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索包内文件", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .disabled(model.current == nil)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            if model.trail.isEmpty {
                Text("未打开归档")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if model.isSearching {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                    Text("搜索「\(model.searchText)」· \(model.displayEntries.count) 个结果")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.trail.enumerated()), id: \.element.id) { index, frame in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        model.popTo(index)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: breadcrumbIcon(index))
                                .font(.system(size: 10))
                            Text(frame.title)
                                .font(.system(size: 12, weight: index == model.trail.count - 1 ? .semibold : .regular))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == model.trail.count - 1 ? Color.primary : Color.secondary)
                }
            }
            Spacer()
            if let current = model.current {
                Text(current.archive.deletingLastPathComponent().path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            if model.viewMode == .list && !model.isSearching {
                HStack(spacing: 0) {
                    Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("大小").frame(width: 90, alignment: .trailing)
                    Text("修改时间").frame(width: 130, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.35))
            }

            if model.displayEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.isSearching ? "magnifyingglass" : "folder")
                        .font(.system(size: 26, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text(model.isSearching ? "没有匹配的文件" : "这个目录是空的")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.viewMode == .icons {
                iconGrid
            } else {
                listView
            }

            if !model.selection.isEmpty {
                flowBar
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(model.displayEntries) { entry in
                row(entry)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    .listRowBackground(
                        model.selection.contains(entry.id)
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 14)], spacing: 14) {
                ForEach(model.displayEntries) { entry in
                    VStack(spacing: 6) {
                        Image(systemName: iconName(entry))
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(entry.isArchive ? Color.accentColor : Color.secondary)
                            .frame(height: 42)
                        Text(entry.name)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(entry.isDirectory ? "文件夹" : entry.displaySize)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 100, height: 96)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(model.selection.contains(entry.id)
                                  ? Color.accentColor.opacity(0.16)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.activate(entry) }
                    .onTapGesture { model.select(entry) }
                    .onDrag { dragProvider(for: entry) }
                    .help(entry.path)
                }
            }
            .padding(16)
        }
    }

    /// 选中后浮出的快捷操作条
    private var flowBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(model.selection.count) 项")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Button("解压到…") { model.extractSelection() }
                .controlSize(.small)
            if let entry = model.displayEntries.first(where: { model.selection.contains($0.id) }),
               !entry.isDirectory {
                Button("导出…") { exportSelected() }
                    .controlSize(.small)
            }
            Button("取消选择") { model.selection = [] }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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

    private func breadcrumbIcon(_ index: Int) -> String {
        guard index < model.trail.count else { return "shippingbox" }
        let frame = model.trail[index]
        let isLast = index == model.trail.count - 1
        if frame.prefix.isEmpty { return isLast ? "shippingbox.fill" : "shippingbox" }
        return isLast ? "folder.fill" : "folder"
    }

    private func row(_ entry: ArchiveEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(entry))
                .font(.system(size: 13))
                .foregroundStyle(entry.isArchive ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                if model.isSearching {
                    Text(entry.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if entry.isArchive {
                Text("嵌套")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 8)

            Text(entry.isDirectory ? "—" : entry.displaySize)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            Text(entry.modified)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 130, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.activate(entry) }
        .onTapGesture { model.select(entry) }
        .onDrag { dragProvider(for: entry) }
        .help(entry.path)
    }

    private func dragProvider(for entry: ArchiveEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            // 回调来自任意队列，必须切回主线程再碰 model
            Task { @MainActor in
                model.payloadURL(for: entry) { url in
                    if let url {
                        completion(url, false, nil)
                    } else {
                        completion(nil, false, ArchiveError.tool("导出 \(entry.name) 失败"))
                    }
                }
            }
            return nil
        }
        return provider
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("把压缩包拖进来")
                .font(.system(size: 15, weight: .medium))
            Text("zip · 7z · rar(只读) · tar · gz · bz2 · xz · zst · cab · iso · xar · 加密包会提示输入密码")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Button("选择文件…") { model.openWithPanel() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !model.archiveSizeText.isEmpty {
                Text(model.archiveSizeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if model.isSearching {
                Text("\(model.displayEntries.count) 个结果")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !model.selection.isEmpty {
                Text("已选 \(model.selection.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func iconName(_ entry: ArchiveEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isArchive { return "shippingbox.fill" }
        switch entry.ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "flac", "wav", "m4a": return "music.note"
        case "txt", "md", "json", "swift", "js", "py", "sh", "html", "css": return "doc.text"
        case "app": return "app"
        default: return "doc"
        }
    }
}
