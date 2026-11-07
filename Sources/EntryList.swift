// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  条目列表、分栏、图标网格、暂存条
//  拆自 ContentView.swift，成员全部是 extension，不持有状态。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
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
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
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
        .onAppear { listFocused = true }
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
        ScrollViewReader { proxy in
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
            }
            .onChange(of: model.selection) { _, selection in
                // 键盘上下移动时要跟着滚动，否则选中项跑出屏幕就看不见了
                guard let id = selection.first else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: model.workspaceMode) { _, _ in
                // 切换模式会重建列表，把选中项重新滚回可见位置（不改变选中状态）
                guard let id = model.selectedEntry?.id else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
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
        }
    }

    var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6)], spacing: 6) {
                ForEach(model.displayEntries) { entry in
                    IconTile(
                        entry: entry,
                        model: model,
                        hover: hover,
                        selected: model.selection.contains(entry.id)
                    )
                }
            }
            .padding(14)
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
        .onTapGesture { model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
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
                .onTapGesture { model.jump(to: entry.path) }
        } else {
            row
                .onTapGesture(count: 2) { model.activate(entry) }
                .onTapGesture { model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
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
        .onTapGesture { model.select(entry, modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
        .onDrag { EntryDrag.provider(for: entry, model: model) }
        .onHover { inside in
            hovering = inside
            if inside { hover.begin(entry, model: model) } else { hover.end() }
        }
        .help(entry.path)
    }
}

