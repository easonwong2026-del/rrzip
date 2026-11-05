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
                    if entry.isDirectory {
                        VStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 44, weight: .thin))
                                .foregroundStyle(FileKind.folder.tint)
                            Text("文件夹")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text("双击进入")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let player {
                        VideoPlayer(player: player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(8)
                    } else if let image {
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
                            Text(note ?? "无法内联预览")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                            if note != nil {
                                Text("可以按空格用快速查看打开")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
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

    private func reset() {
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
