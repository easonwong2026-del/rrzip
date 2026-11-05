// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Mini：常驻置顶的小窗。拖入即看，双击进目录，拖文件出来。
/// 独立 model 实例，不影响主窗口状态。
@MainActor
final class MiniPanelController {
    static let shared = MiniPanelController()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 384, height: 470),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "rrzip mini"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 320)
        panel.contentView = NSHostingView(rootView: MiniView())
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func toggle() {
        if isVisible { panel?.orderOut(nil) } else { show() }
    }
}

struct MiniView: View {
    @StateObject private var model = ArchiveModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.current == nil {
                emptyState
            } else {
                list
                if !model.selection.isEmpty { actionBar }
            }

            Divider()
            footer
        }
        .frame(minWidth: 320, minHeight: 320)
        .background(.background)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .task {
            // 调试用：defaults write com.rrzip.mac rrzip.miniArchive /path/to.zip
            if let path = UserDefaults.standard.string(forKey: "rrzip.miniArchive") {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) { model.open(url: url) }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.open(url: url) }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoBack)
            .opacity(model.canGoBack ? 1 : 0.3)

            Text(model.current?.title ?? "rrzip mini")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                model.openWithPanel()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .help("打开压缩包")

            Button {
                AppDelegate.model.map { main in
                    if let archive = model.current?.archive { main.open(url: archive) }
                }
                NSApp.activate(ignoringOtherApps: true)
                MiniPanelController.shared.toggle()
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .help("在主窗口打开")
            .disabled(model.current == nil)
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private var list: some View {
        List {
            ForEach(model.displayEntries) { entry in
                HStack(spacing: 7) {
                    EntryThumbnail(entry: entry, model: model, side: 18, corner: 4)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if entry.isDirectory {
                            Text("文件夹")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 4)
                    if !entry.isDirectory {
                        Text(entry.displaySize)
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
                .listRowBackground(
                    model.selection.contains(entry.id)
                        ? Color.accentColor.opacity(0.16)
                        : Color.clear
                )
                .contentShape(Rectangle())
                .onTapGesture { model.select(entry) }
                .onTapGesture(count: 2) { model.activate(entry) }
                .onDrag { dragProvider(for: entry) }
                .help(entry.path)
            }
        }
        .listStyle(.inset)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Text("已选 \(model.selection.count) 项")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("解压…") { model.extractSelection() }
                .controlSize(.small)
            Button("取消") { model.selection = [] }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isLoading {
                ProgressView().controlSize(.mini)
            }
            Text(model.status)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("拖一个压缩包进来")
                .font(.system(size: 12, weight: .medium))
            Text("看完就走，不用开主窗口")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Button("选择文件…") { model.openWithPanel() }
                .controlSize(.small)
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dragProvider(for entry: ArchiveEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
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
}
