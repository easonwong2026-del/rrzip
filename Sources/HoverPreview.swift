// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import SwiftUI
import PDFKit

/// 悬停预览：鼠标在列表行上停满 1 秒，在光标旁弹一张内容卡片。
/// 不抢焦点、不接管鼠标事件，移开就消失。
/// 窗口刚打开、鼠标恰好停在列表上时不弹：必须先观察到鼠标真的移动过，
/// 否则每次开包都会有一张卡片直接盖在内容上。
@MainActor
final class HoverCoordinator: ObservableObject {
    private var pending: Task<Void, Never>?
    private var lastPoint: NSPoint?
    private var sawMovement = false

    func begin(_ entry: ArchiveEntry, model: ArchiveModel, at point: NSPoint? = nil) {
        pending?.cancel()

        let current = NSEvent.mouseLocation
        if let last = lastPoint, abs(current.x - last.x) + abs(current.y - last.y) > 2 {
            sawMovement = true
        }
        lastPoint = current

        guard !entry.isDirectory else {
            HoverPreviewPanel.shared.hide()
            return
        }
        // 显式传坐标的是调试入口（--demo-hover），不卡「先移动」这条
        guard sawMovement || point != nil else { return }

        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
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
        .preferredColorScheme(AppearanceMode.stored.scheme)
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

        let url = await model.payloadURL(for: entry)
        // 读这几 KB 期间别让回收把文件抽走；登记带路径，自动回收也认
        if let url { ScratchUsage.shared.beginWork(on: url.path) }
        defer { if let url { ScratchUsage.shared.endWork(on: url.path) } }
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
    private var resignObserver: NSObjectProtocol?

    private init() {
        // 切到别的 App 时鼠标不再给列表发事件，卡片会留在别人窗口上面
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in HoverPreviewPanel.shared.hide() }
        }
    }

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
