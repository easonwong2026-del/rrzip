// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  条目列表、分栏、图标网格、暂存条
//  拆自 ContentView.swift，成员全部是 extension，不持有状态。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    /// 图标网格量出来的实际宽度，用来算一行几列（下键按行跳）
    var gridColumns: Int {
        guard !model.isCompactMode, model.viewMode == .icons else { return 1 }
        return IconGridLayout.columns(forWidth: gridWidth)
    }

    /// 布局刚换过：新滚动容器这一帧还没建好，它的首次同步只会记基线。
    /// 连发两次（下一拍 + 80ms 后），第二次一定落在新容器建好之后；
    /// 已经可见时 `EntryScroll.minimalDelta` 返回 nil，多发一次不会多滚。
    func requestLayoutReveal() {
        DispatchQueue.main.async { entryRevealTick &+= 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { entryRevealTick &+= 1 }
    }

    var compactWorkspace: some View {
        GeometryReader { proxy in
            entryList
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(alignment: .trailing) {
                    // 太窄时浮层会把列表压没，此时只保留空格快速查看
                    if proxy.size.width >= Layout.overlayPreviewMinWidth,
                       let entry = model.selectedEntry, !entry.isDirectory {
                        compactPreview
                            .padding(.trailing, Space.l)
                            .padding(.top, Space.l)
                            // 给底部选中操作条让位，否则浮层压住「解压到文件夹…」
                            .padding(.bottom, Metrics.flowBarHeight + Space.m)
                    }
                }
        }
        .frame(idealWidth: 720, idealHeight: 460)
    }

    var compactPreview: some View {
        PreviewPane(model: model)
            .frame(width: Metrics.overlayPreviewWidth)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
            .transition(.opacity)
    }

    // MARK: 条目区

    var entryList: some View {
        VStack(spacing: 0) {
            // 简化模式固定列表：图标网格和分栏留到工作台里用，不在这里挤
            if model.isCompactMode || model.viewMode == .list {
                listHeader
            }

            if model.displayEntries.isEmpty {
                emptyFolder
            } else if !model.isCompactMode && model.viewMode == .icons {
                iconGrid
            } else if !model.isCompactMode && model.viewMode == .columns && !model.isSearching {
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
            model.moveSelection(by: -1, columns: gridColumns)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1, columns: gridColumns)
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
        // 三种视图共用同一个「滚到可见」信号：键盘导航与切换布局时才发，
        // 鼠标选中一律不发，单击就不会带着列表跳
        .onChange(of: model.keyboardScrollTick) { _, _ in entryRevealTick &+= 1 }
        // 换视图 / 换工作模式会重建整个滚动容器：新的 follower 首次同步只记基线，
        // 所以要等这一轮布局落地之后再补发信号，否则「选中项被带过去」这一步落空
        .onChange(of: model.layoutTick) { _, _ in requestLayoutReveal() }
        // 内容整批换掉时回到顶部：改关键词、进/出目录、换包
        .onChange(of: model.searchText) { _, _ in entryScrollTopTick &+= 1 }
        .onChange(of: model.current?.id) { _, _ in entryScrollTopTick &+= 1 }
        .onAppear {
            // 搜索框正在输入时不要抢焦点
            if !searchFocused { listFocused = true }
        }
    }

    var listHeader: some View {
        HStack(spacing: 8) {
            headerCell("名称", key: .name, leading: 28, alignLeading: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell("大小", key: .size, leading: 0, alignLeading: false)
                .frame(width: Metrics.sizeColumn)
            headerCell("修改时间", key: .modified, leading: 0, alignLeading: false)
                .frame(width: Metrics.dateColumn)
        }
        .font(TypeScale.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// 表头可点：同一列再点一次换方向，目录永远在前
    func headerCell(_ title: String, key: SortKey,
                            leading: CGFloat, alignLeading: Bool) -> some View {
        Button {
            model.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sortKey == key {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .padding(.leading, leading)
            .frame(maxWidth: .infinity, alignment: alignLeading ? .leading : .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    var emptyFolder: some View {
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

    var listView: some View {
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
            .background(EntryScrollTopMarker(tick: entryScrollTopTick))
            .overlay { listRevealMarker }
        }
    }

    /// 列表行高固定（搜索时多一行路径），滚动落点直接按索引算
    var listRowHeight: CGFloat {
        model.isSearching ? Metrics.rowHeightWide : Metrics.rowHeight
    }

    var listRevealMarker: some View {
        let entries = model.displayEntries
        return EntryRevealMarker(
            tick: entryRevealTick,
            count: entries.count,
            index: entries.firstIndex { model.selection.contains($0.id) },
            metrics: { index, contentHeight in
                // 从底部反推：不用假设顶部内边距，行高是唯一常量
                let height = listRowHeight
                let y = contentHeight - 6 - CGFloat(entries.count - index) * height
                return (y: y, height: height)
            }
        )
    }

    /// 分栏视图：每列一层目录，点目录在右侧开新列（类似访达的列视图）
    var columnsView: some View {
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

    func columnView(frame: ArchiveModel.Frame, isLast: Bool) -> some View {
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
            .overlay {
                // 只有最后一列会承接键盘导航，其余列不用跟
                if isLast {
                    EntryRevealMarker(
                        tick: entryRevealTick,
                        count: items.count,
                        index: items.firstIndex { model.selection.contains($0.id) },
                        metrics: { index, contentHeight in
                            let height = Metrics.columnRowHeight
                            return (y: contentHeight - 6 - CGFloat(items.count - index) * height,
                                    height: height)
                        }
                    )
                }
            }
        }
    }

    var iconGrid: some View {
        let entries = model.displayEntries
        let columns = IconGridLayout.columns(forWidth: gridWidth)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: IconGridLayout.tileMin),
                                         spacing: IconGridLayout.spacing)],
                      spacing: IconGridLayout.spacing) {
                ForEach(entries) { entry in
                    IconTile(
                        entry: entry,
                        model: model,
                        hover: hover,
                        selected: model.selection.contains(entry.id)
                    )
                    .id(entry.id)
                }
            }
            .padding(IconGridLayout.padding)
            .background(EntryScrollTopMarker(tick: entryScrollTopTick))
            .background(
                // 只是量宽度：列数决定下键跳几格、滚动落点落在哪一格
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { gridWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in gridWidth = width }
                }
            )
            .overlay {
                EntryRevealMarker(
                    tick: entryRevealTick,
                    count: entries.count,
                    index: entries.firstIndex { model.selection.contains($0.id) },
                    metrics: { index, contentHeight in
                        // 网格的格子高度随字号/行数固定，但不想在这里再写死一份：
                        // 由内容总高反推行距，行距减去间距就是格子高度
                        let rows = max(1, Int(ceil(Double(entries.count) / Double(columns))))
                        let padding = IconGridLayout.padding
                        let spacing = IconGridLayout.spacing
                        let pitch = (contentHeight - padding * 2 + spacing) / CGFloat(rows)
                        let row = index / columns
                        return (y: padding + CGFloat(row) * pitch,
                                height: max(1, pitch - spacing))
                    }
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// 选中后浮出的快捷操作条。
    /// 三栏收到最窄（818）时按钮会被挤出可视区、只剩「解压…」三个字，
    /// 所以给它一个更短的版式，由 ViewThatFits 按实际宽度挑。
    var flowBar: some View {
        ViewThatFits(in: .horizontal) {
            flowBarRow(compact: false)
            flowBarRow(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
    }

    func flowBarRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.brand)
                Text(compact ? "\(model.selection.count) 项" : "已选 \(model.selection.count) 项")
                    .font(TypeScale.label.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Palette.brand.opacity(0.10), in: Capsule())

            Spacer(minLength: 8)

            Button(compact ? "解压…" : "解压到文件夹…") { model.extractSelection() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("解压选中的 \(model.selection.count) 项到文件夹…")
            if let entry = model.selectedEntry,
               SaveAsFlow.allowsSingleFileExport(selectionCount: model.selection.count,
                                                 isDirectory: entry.isDirectory) {
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
    }

    func exportSelected() {
        // 多选不静默只存第一个：批量走「解压选中项」或暂存区导出
        guard let entry = model.selectedEntry,
              SaveAsFlow.allowsSingleFileExport(selectionCount: model.selection.count,
                                                isDirectory: entry.isDirectory)
        else { return }
        SaveAsFlow.present(entry, model: model)
    }

    // MARK: 暂存区

    var stashBar: some View {
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

}

// MARK: - 滚到可见

/// 把选中项按**最小位移**滚进视口；已经完整可见就一步都不动。
///
/// 不用 `ScrollViewReader.scrollTo(anchor: .center)`：那个 API 只要选中项变了
/// 就滚，而且一定把目标摆到视口正中——鼠标单击一行整页就跳，⌘A 更是按
/// `Set.first`（无序）随手挑一条居中。这里换成 AppKit 的滚动语义：
/// 只补「超出视口的那点差值」。
///
/// 落点由调用方按索引算好（行高固定，不需要该行真的被渲染出来）：
/// LazyVStack 里视口外的那一行根本不存在，靠「行视图 onAppear」是滚不到它的。
struct EntryScrollFollower: NSViewRepresentable {
    let tick: Int
    /// 只有「当前这一项」才该被滚出来；没选中的标记不动滚动位置
    let active: Bool

    func makeNSView(context: Context) -> FollowerView { FollowerView() }

    func updateNSView(_ view: FollowerView, context: Context) {
        view.sync(tick: tick, active: active)
    }

    final class FollowerView: NSView {
        private var gate = EntryRevealGate()

        /// 纯定位标记，不吃鼠标事件（拖拽、右键、单击都要落到行上）
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var isFlipped: Bool { true }

        func sync(tick: Int, active: Bool) {
            guard gate.shouldReveal(tick: tick, active: active) else { return }
            attemptReveal(0)
        }

        /// 视图刚换过来的前几帧，标记还没有窗口/尺寸（ScrollView 还在建），
        /// 这时算出来的矩形不可信。等一帧再试，最多重试 8 次（≈0.2s）就放弃。
        private func attemptReveal(_ attempt: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.reveal() { return }              // 布局就绪（滚不滚另说）
                guard attempt < 8 else { return }        // 还没就绪：下一拍再试
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.attemptReveal(attempt + 1)
                }
            }
        }

        /// - Returns: true 表示布局已就绪（滚不滚另说）；false 表示还没就绪，值得重试
        @discardableResult
        private func reveal() -> Bool {
            guard window != nil, bounds.height > 0.5, let clip = enclosingClipView() else { return false }
            let row = convert(bounds, to: clip)
            guard let delta = EntryScroll.minimalDelta(row: row,
                                                       visible: clip.bounds,
                                                       contentHeight: clip.documentRect.height)
            else { return true }
            #if DEBUG
            // 只有真的滚了才记：排查「单击也跳」这类时序问题靠这行
            DebugLog.reveal("scroll delta=\(delta) row=\(row) visible=\(clip.bounds)")
            #endif
            var target = clip.bounds.origin
            target.y += delta
            clip.scroll(to: target)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
            return true
        }
    }
}

/// 列表内容整批换掉（改关键词、进目录、换包）时回到顶部。
/// 不回到顶部的话，17 条搜索结果会停在上一份内容留下的滚动位置上，
/// 头几条根本看不见，看着像「没搜到」。
struct EntryScrollTopMarker: NSViewRepresentable {
    let tick: Int

    func makeNSView(context: Context) -> TopView { TopView() }

    func updateNSView(_ view: TopView, context: Context) {
        view.sync(tick: tick)
    }

    final class TopView: NSView {
        private var lastTick: Int?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override var isFlipped: Bool { true }

        func sync(tick: Int) {
            defer { lastTick = tick }
            guard let lastTick, lastTick != tick else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, let clip = self.enclosingClipView() else { return }
                clip.scroll(to: NSPoint(x: 0, y: 0))
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
    }
}

/// 按索引把「选中项应该在的位置」摆成一个隐藏标记，交给 `EntryScrollFollower`。
/// 三种视图共用：各自只需要说清楚「第 index 项在内容里的 y 和高度」，
/// 滚动策略（已可见不动、只走最小位移）只有一份。
struct EntryRevealMarker: View {
    let tick: Int
    let count: Int
    let index: Int?
    /// (第几项, 内容总高) → 该项在内容坐标系里的 y 与高度
    let metrics: (Int, CGFloat) -> (y: CGFloat, height: CGFloat)

    var body: some View {
        GeometryReader { proxy in
            if let index, count > 0 {
                let box = metrics(index, proxy.size.height)
                EntryScrollFollower(tick: tick, active: true)
                    .frame(height: max(1, box.height))
                    .offset(y: box.y)
            }
        }
        .allowsHitTesting(false)
    }
}

extension NSView {
    /// SwiftUI 的 ScrollView 底下就是 NSScrollView；往上找到最近的 clip view
    func enclosingClipView() -> NSClipView? {
        var view = superview
        while let current = view {
            if let clip = current as? NSClipView { return clip }
            view = current.superview
        }
        return nil
    }
}

/// 鼠标点中一行之后，把键盘交还列表。
/// 焦点还停在搜索框里时，方向键在挪光标、Return 在提交输入、空格在打字，
/// 看起来像「点了行但键盘不听话」。只在这一步切，边输入边跳结果时不动焦点。
@MainActor
func takeKeyboardFocus() {
    NotificationCenter.default.post(name: .rrzipFocusList, object: nil)
}

// MARK: - 列表行

struct EntryRow: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    @ObservedObject var hover: HoverCoordinator
    let selected: Bool
    let showPath: Bool

    @State var hovering = false

    var rowHeight: CGFloat {
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
                // 只是一条提示：以前用「嵌套」胶囊，34pt 全是从文件名那里借的
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(FileKind.archive.tint.opacity(0.85))
                    .help("嵌套压缩包，双击展开")
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
                      ? Palette.selectionFill
                      : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .strokeBorder(selected ? Palette.selectionStroke : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.activate(entry) }
        .onTapGesture {
            model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
            takeKeyboardFocus()
        }
        .onDrag { EntryDrag.provider(for: entry, model: model) }
        .onHover { inside in
            hovering = inside
            if inside { hover.begin(entry, model: model) } else { hover.end() }
        }
        .contextMenu {
            // 右键已选中的条目保留整组选择；右键未选中的条目才切单选（跟访达一致）
            let group = model.selection.contains(entry.id) ? model.selection.count : 1

            Button(entry.isDirectory ? "进入文件夹" : (entry.isArchive ? "进入压缩包" : "打开")) {
                model.prepareContextSelection(entry)
                model.activate(entry)
            }
            Button(group > 1 ? "解压 \(group) 项到…" : "解压到…") {
                model.prepareContextSelection(entry)
                model.extractSelection()
            }
            Button("另存为…") {
                model.prepareContextSelection(entry)
                SaveAsFlow.present(entry, model: model)
            }
            .disabled(entry.isDirectory || group > 1)
            Divider()
            Button("加入暂存区") {
                model.prepareContextSelection(entry)
                model.addSelectionToStash()
            }
            .disabled(entry.isDirectory)
            Button("加入文件…") { model.addFiles() }
                .disabled(model.isNested)
            Button(group > 1 ? "删除这 \(group) 项…" : "从压缩包删除…") {
                model.prepareContextSelection(entry)
                model.deleteSelection()
            }
            .foregroundStyle(.red)
            .disabled(model.isNested)
        }
        .help(entry.path)
    }
}

// MARK: - 分栏行

struct ColumnRow: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    @ObservedObject var hover: HoverCoordinator
    let selected: Bool

    @State var hovering = false

    var body: some View {
        // 目录只在单击时跳转（等价访达列视图：在右侧开下一列）。
        // 不能再挂双击 activate——单击已经 jump 过一次，双击会再 push 一层，
        // 面包屑出现「照片 › 照片」，看起来就像套了一层。
        if entry.isDirectory {
            row
                .onTapGesture {
                    model.jump(to: entry.path)
                    takeKeyboardFocus()
                }
        } else {
            row
                .onTapGesture(count: 2) { model.activate(entry) }
                .onTapGesture {
                    model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                    takeKeyboardFocus()
                }
        }
    }

    var row: some View {
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
                      ? Palette.selectionFill
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

struct IconTile: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    @ObservedObject var hover: HoverCoordinator
    let selected: Bool

    @State var hovering = false

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
                      ? Palette.selectionFill
                      : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Palette.selectionStroke : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.activate(entry) }
        .onTapGesture {
            model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
            takeKeyboardFocus()
        }
        .onDrag { EntryDrag.provider(for: entry, model: model) }
        .onHover { inside in
            hovering = inside
            if inside { hover.begin(entry, model: model) } else { hover.end() }
        }
        .help(entry.path)
    }
}

