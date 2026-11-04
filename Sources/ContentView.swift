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

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: ArchiveModel?

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

            if model.entries.isEmpty {
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
            // 支持 `open -a 归档坞 xxx.zip` 以及命令行直接传路径
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
        HStack(spacing: 10) {
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
                Label("新建压缩包", systemImage: "archivebox")
            }

            Spacer()

            if model.isEncrypted {
                Button {
                    model.lockCurrent()
                } label: {
                    Label("已解锁", systemImage: "lock.open.fill")
                        .foregroundStyle(.orange)
                }
                .help("点击锁定并清除本次会话的密码")
            }

            if model.isLoading { ProgressView().controlSize(.small) }

            Button {
                model.revealInFinder()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("在访达中显示")
            .disabled(model.current == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            if model.trail.isEmpty {
                Text("未打开归档")
                    .font(.system(size: 12))
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
                            Image(systemName: index == model.trail.count - 1 ? "shippingbox.fill" : "shippingbox")
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

            List(selection: $model.selection) {
                ForEach(model.entries) { entry in
                    row(entry)
                        .tag(entry.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    private func row(_ entry: ArchiveEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(entry))
                .font(.system(size: 13))
                .foregroundStyle(entry.isArchive ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            Text(entry.name)
                .font(.system(size: 12.5))
                .lineLimit(1)

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
        .onTapGesture(count: 2) {
            if entry.isArchive { model.enter(entry) }
        }
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
        HStack(spacing: 8) {
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
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
