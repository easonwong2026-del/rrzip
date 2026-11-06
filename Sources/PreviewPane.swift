// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import AVKit
import PDFKit
import SwiftUI

struct PreviewPane: View {
    @ObservedObject var model: ArchiveModel

    @State private var payload: URL?
    @State private var image: NSImage?
    @State private var text: String?
    @State private var pdf: PDFDocument?
    @State private var player: AVPlayer?
    @State private var loading = false
    /// 图片缩放：0 = 适应面板；>0 = 实际像素倍数。切换选中时复位
    @State private var zoom: CGFloat = 0
    /// 不能内联时的具体原因（过大 / 引擎不支持）
    @State private var note: String?

    /// 视频解压后要整份落到临时目录，太大就交给快速查看
    private static let videoLimit: Int64 = 800 * 1024 * 1024
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mpg", "mpeg"]
    private static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"]

    /// 选中项 + 刷新令牌，重复点同一行也会重新加载
    private var previewKey: String {
        "\(selectedEntry?.id ?? "none")|\(model.previewToken)"
    }

    /// 用模型里的顺序选中项，别直接取 Set.first（多选时顺序是随机的）
    private var selectedEntry: ArchiveEntry? { model.selectedEntry }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: previewKey) { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("预览")
                .font(TypeScale.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let entry = selectedEntry {
                Text(entry.isDirectory ? "文件夹" : entry.displaySize)
                    .font(TypeScale.data(10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                if !entry.isDirectory {
                    ToolButton(symbol: "arrow.up.right.square",
                               help: "用默认程序打开（临时副本，修改不会写回）",
                               inactive: payload == nil) {
                        if let payload { NSWorkspace.shared.open(payload) }
                    }
                    ToolButton(symbol: "square.and.arrow.down", help: "另存为…") {
                        export(entry)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.brand)
                Text("正在读取…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let entry = selectedEntry {
            VStack(spacing: 0) {
                stage(entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Hairline()
                meta(entry)
            }
        } else {
            emptyState
        }
    }

    // MARK: 预览舞台

    @ViewBuilder
    private func stage(_ entry: ArchiveEntry) -> some View {
        if entry.isDirectory {
            placeholder(symbol: "folder.fill", tint: FileKind.folder.tint,
                        title: "文件夹", note: "双击进入")
        } else if let player {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(10)
        } else if let image {
            imageStage(image)
                .overlay(alignment: .bottomTrailing) { zoomControls }
        } else if let pdf {
            PDFKitView(document: pdf)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                )
                .padding(10)
        } else if let text {
            ScrollView {
                Text(text)
                    .font(TypeScale.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .padding(10)
        } else {
            placeholder(symbol: fallbackIcon(entry),
                        tint: FileKind(entry).tint,
                        title: note ?? "无法内联预览",
                        note: note == nil ? "按空格用快速查看打开" : "按空格用快速查看打开")
        }
    }

    // MARK: 图片缩放

    @ViewBuilder
    private func imageStage(_ image: NSImage) -> some View {
        if zoom == 0 {
            // 用 GeometryReader 拿到面板的真实宽高再 fit：
            // 光靠 maxWidth/maxHeight 的弹性约束，在分栏里会被图片的固有尺寸撑出去
            GeometryReader { proxy in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: max(0, proxy.size.width - 20),
                           height: max(0, proxy.size.height - 20))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { zoom = 1 }
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                    .contentShape(Rectangle())
                    .onTapGesture { zoom = 0 }
                    .padding(10)
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 5) {
            Button { zoom = max(0.1, (zoom == 0 ? 1 : zoom) - 0.25) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { zoom = 0 } label: {
                Text(zoom == 0 ? "适应" : "\(Int(zoom * 100))%")
                    .font(TypeScale.data(9.5))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30)
            }
            .buttonStyle(.plain)
            .help("回到适应面板")

            Button { zoom = min(4, (zoom == 0 ? 1 : zoom) + 0.25) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 10)

            Button { zoom = zoom == 0 ? 1 : 0 } label: {
                Text(zoom == 0 ? "1:1" : "适应")
                    .font(.system(size: 9.5, weight: .medium))
                    .frame(minWidth: 22)
            }
            .buttonStyle(.plain)
            .help(zoom == 0 ? "按实际像素查看" : "适应面板大小")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
        .padding(16)
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }

    private func placeholder(symbol: String, tint: Color, title: String, note: String) -> some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.10))
                    .frame(width: 62, height: 62)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(TypeScale.bodySmall.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.045))
                    .frame(width: 62, height: 62)
                Image(systemName: "eye")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text("选中一个项目查看预览")
                .font(TypeScale.bodySmall.weight(.medium))
                .foregroundStyle(.secondary)
            Text("空格键快速查看")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部信息

    private func meta(_ entry: ArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.path)
                .font(TypeScale.mono)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 5) {
                Text(entry.isDirectory ? "文件夹" : entry.displaySize)
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(entry.modified)
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func reset() {
        zoom = 0
        payload = nil; image = nil; text = nil; pdf = nil
        player?.pause()
        player = nil
        note = nil
    }

    private func load() async {
        // 目录或取消选中：必须把 loading 关掉，否则会一直转菊花
        guard let entry = selectedEntry, !entry.isDirectory else {
            reset()
            loading = false
            return
        }
        let token = entry.id
        loading = true
        reset()

        let url: URL? = await withCheckedContinuation { continuation in
            model.payloadURL(for: entry) { continuation.resume(returning: $0) }
        }

        // 选中项已经换了就丢弃这次结果，避免显示上一个文件
        guard !Task.isCancelled, selectedEntry?.id == token else { return }
        loading = false
        guard let url else { return }
        payload = url

        let ext = entry.ext
        if Self.videoExts.contains(ext) || Self.audioExts.contains(ext) {
            guard entry.size <= Self.videoLimit else {
                note = "文件较大（\(entry.displaySize)），不在面板内加载"
                return
            }
            player = AVPlayer(playerItem: AVPlayerItem(url: url))
            return
        }

        switch ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp":
            image = NSImage(contentsOf: url)
        case "pdf":
            pdf = PDFDocument(url: url)
        case "txt", "md", "json", "swift", "js", "ts", "py", "sh", "html", "css", "xml", "yml", "yaml", "log", "csv":
            let data = (try? Data(contentsOf: url, options: .mappedIfSafe))?.prefix(120_000)
            if let data { text = String(decoding: data, as: UTF8.self) }
        default:
            note = "这种格式没有内联预览"
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
