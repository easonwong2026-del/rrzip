// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import SwiftUI
import PDFKit

/// 悬停预览：鼠标在列表行上停 0.4 秒，在光标旁弹一张内容卡片。
/// 不抢焦点、不接管鼠标事件，移开就消失。
@MainActor
final class HoverCoordinator: ObservableObject {
    private var pending: Task<Void, Never>?

    func begin(_ entry: ArchiveEntry, model: ArchiveModel, at point: NSPoint? = nil) {
        pending?.cancel()
        guard !entry.isDirectory else {
            HoverPreviewPanel.shared.hide()
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.show(entry, model: model, at: point)
        }
    }

    private func show(_ entry: ArchiveEntry, model: ArchiveModel, at point: NSPoint?) {
        HoverPreviewPanel.shared.show(entry: entry, model: model, at: point ?? NSEvent.mouseLocation)
    }

    func end() {
        pending?.cancel()
        pending = nil
        HoverPreviewPanel.shared.hide()
    }
}

/// 内容卡片本体
struct HoverCard: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel

    @State private var image: CGImage?
    @State private var text: String?
    @State private var failed = false

    private static let textExts: Set<String> = [
        "txt", "md", "json", "xml", "yml", "yaml", "csv", "log", "ini", "conf",
        "swift", "js", "ts", "py", "rb", "go", "rs", "java", "c", "h", "cpp",
        "html", "css", "sh", "zsh", "toml", "gradle", "sql"
    ]

    private var isText: Bool { Self.textExts.contains(entry.ext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(width: 280, height: 180)
                .clipped()

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(entry.displaySize)
                    if !entry.modified.isEmpty { Text(entry.modified) }
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 280, alignment: .leading)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
        .task(id: entry.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else if let text {
            ScrollView {
                Text(text)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else if failed {
            placeholder(symbol: "exclamationmark.triangle", note: "无法预览")
        } else {
            placeholder(symbol: symbolicName, note: "正在读取…")
        }
    }

    private func placeholder(symbol: String, note: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var symbolicName: String {
        switch entry.ext {
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "flac", "wav", "m4a": return "music.note"
        default: return "doc"
        }
    }

    private func load() async {
        if ThumbnailStore.shared.supports(entry) {
            let loaded: CGImage? = await withCheckedContinuation { continuation in
                ThumbnailStore.shared.thumbnail(for: entry, model: model, maxPixel: 560) { image in
                    continuation.resume(returning: image)
                }
            }
            await MainActor.run {
                image = loaded
                failed = loaded == nil
            }
            return
        }

        guard isText else {
            await MainActor.run { failed = true }
            return
        }

        let url: URL? = await withCheckedContinuation { continuation in
            model.payloadURL(for: entry) { continuation.resume(returning: $0) }
        }
        guard let url,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            await MainActor.run { failed = true }
            return
        }
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        await MainActor.run { text = prefix }
    }
}

/// 无边框浮窗：不激活、不接收鼠标，只负责画
@MainActor
final class HoverPreviewPanel {
    static let shared = HoverPreviewPanel()
    private var panel: NSPanel?

    func show(entry: ArchiveEntry, model: ArchiveModel, at point: NSPoint) {
        hide()

        let size = NSSize(width: 280, height: 232)
        let panel = NSPanel(
            contentRect: NSRect(origin: point, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let host = NSHostingView(rootView: HoverCard(entry: entry, model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        // 放在光标右上方，贴边时翻到另一侧
        var origin = NSPoint(x: point.x + 18, y: point.y - size.height + 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX { origin.x = point.x - size.width - 18 }
            if origin.y < visible.minY { origin.y = visible.minY + 8 }
            if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height - 8 }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}
