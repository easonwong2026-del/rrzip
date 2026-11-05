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

/// Mini 的多标签容器：每个标签一份独立 model，互不干扰
@MainActor
final class MiniTabs: ObservableObject {
    @MainActor
    struct Tab: Identifiable {
        let id = UUID()
        let model = ArchiveModel()
        var title: String {
            model.current?.archive.deletingPathExtension().lastPathComponent ?? "未命名"
        }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var activeID: UUID?

    var active: Tab? {
        tabs.first { $0.id == activeID } ?? tabs.first
    }

    /// 每个标签持有一份完整条目列表，开太多会明显吃内存
    static let maxTabs = 8

    func open(_ url: URL) {
        if let existing = tabs.first(where: { $0.model.current?.archive == url }) {
            activeID = existing.id
            return
        }
        if tabs.count >= Self.maxTabs {
            // 关掉最早的一个，给新标签腾位置
            if let oldest = tabs.first { close(oldest.id) }
        }
        let tab = Tab()
        tabs.append(tab)
        activeID = tab.id
        tab.model.open(url: url)
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if activeID == id {
            activeID = tabs[safe: index]?.id ?? tabs.last?.id
        }
    }

    func select(_ id: UUID) { activeID = id }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct MiniView: View {
    @StateObject private var tabs = MiniTabs()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if tabs.tabs.count > 1 {
                tabStrip
                Divider()
            }
            if let tab = tabs.active {
                MiniBody(model: tab.model, tabs: tabs)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 320, minHeight: 320)
        .background(.background)
        .preferredColorScheme(AppearanceMode.stored.scheme)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.brand, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
#if DEBUG
        .task {
            // 调试用：defaults write com.rrzip.mac rrzip.miniArchive /path/to.zip
            if let paths = UserDefaults.standard.string(forKey: "rrzip.miniArchive"),
               tabs.tabs.isEmpty {
                for path in paths.split(separator: ",") {
                    let url = URL(fileURLWithPath: String(path))
                    if FileManager.default.fileExists(atPath: url.path) { tabs.open(url) }
                }
            }
        }
#endif
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in tabs.open(url) }
            }
            return true
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs.tabs) { tab in
                    HStack(spacing: 4) {
                        Text(tab.title)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                        Button {
                            tabs.close(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tabs.activeID == tab.id ? Palette.brand.opacity(0.18) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { tabs.select(tab.id) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 22)
            .padding(.bottom, 5)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("拖一个压缩包进来")
                .font(.system(size: 12, weight: .medium))
            Text("看完就走，不用开主窗口；再拖一个会开新标签")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Button("选择文件…") { pickFile() }
                .controlSize(.small)
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { tabs.open(url) }
    }
}

/// 单个标签的内容
struct MiniBody: View {
    @ObservedObject var model: ArchiveModel
    @ObservedObject var tabs: MiniTabs

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            if !model.selection.isEmpty { actionBar }
            Divider()
            footer
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
                pick()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .help("再开一个标签")

            Button {
                if let archive = model.current?.archive {
                    AppDelegate.model?.open(url: archive)
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
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { tabs.open(url) }
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
                        ? Palette.brand.opacity(0.16)
                        : Color.clear
                )
                .contentShape(Rectangle())
                .onTapGesture { model.select(entry) }
                .onTapGesture(count: 2) { model.activate(entry) }
                .onDrag { EntryDrag.provider(for: entry, model: model) }
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
            if model.isLoading { ProgressView().controlSize(.mini) }
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
}
