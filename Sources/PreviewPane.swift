import AppKit
import PDFKit
import SwiftUI

struct PreviewPane: View {
    @ObservedObject var model: ArchiveModel

    @State private var payload: URL?
    @State private var image: NSImage?
    @State private var text: String?
    @State private var pdf: PDFDocument?
    @State private var loading = false

    /// 选中项 + 刷新令牌，重复点同一行也会重新加载
    private var previewKey: String {
        "\(selectedEntry?.id ?? "none")|\(model.previewToken)"
    }

    private var selectedEntry: ArchiveEntry? {
        guard let id = model.selection.first else { return nil }
        return model.entries.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
        .task(id: previewKey) { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .font(.system(size: 11))
            Text("预览")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            if let entry = selectedEntry {
                Text(entry.isDirectory ? "文件夹" : entry.displaySize)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let entry = selectedEntry {
            VStack(spacing: 0) {
                Group {
                    if let image {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(8)
                        }
                    } else if let pdf {
                        PDFKitView(document: pdf)
                    } else if let text {
                        ScrollView {
                            Text(text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: fallbackIcon(entry))
                                .font(.system(size: 44, weight: .thin))
                                .foregroundStyle(.tertiary)
                            Text("无法内联预览")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text("\(entry.isDirectory ? "—" : entry.displaySize) · 修改于 \(entry.modified)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        Button("打开") {
                            if let payload { NSWorkspace.shared.open(payload) }
                        }
                        .controlSize(.small)
                        Button("导出…") { export(entry) }
                            .controlSize(.small)
                        Spacer()
                    }
                }
                .padding(10)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("选中一个项目查看预览")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        guard let entry = selectedEntry, !entry.isDirectory else {
            payload = nil; image = nil; text = nil; pdf = nil
            return
        }
        let token = entry.id
        loading = true
        payload = nil; image = nil; text = nil; pdf = nil

        let url: URL? = await withCheckedContinuation { continuation in
            model.payloadURL(for: entry) { continuation.resume(returning: $0) }
        }

        // 选中项已经换了就丢弃这次结果，避免显示上一个文件
        guard !Task.isCancelled, selectedEntry?.id == token else { return }
        loading = false
        guard let url else { return }
        payload = url

        switch entry.ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp":
            image = NSImage(contentsOf: url)
        case "pdf":
            pdf = PDFDocument(url: url)
        case "txt", "md", "json", "swift", "js", "ts", "py", "sh", "html", "css", "xml", "yml", "yaml", "log", "csv":
            let data = (try? Data(contentsOf: url, options: .mappedIfSafe))?.prefix(120_000)
            if let data { text = String(decoding: data, as: UTF8.self) }
        default:
            break
        }
    }

    private func export(_ entry: ArchiveEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let payload {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: payload, to: destination)
        }
    }

    private func fallbackIcon(_ entry: ArchiveEntry) -> String {
        entry.isArchive ? "shippingbox" : "doc"
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = document
    }
}
