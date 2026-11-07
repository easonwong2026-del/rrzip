// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  工具栏与其上的控件
//  拆自 ContentView.swift，成员全部是 extension，不持有状态。

import AppKit
import SwiftUI

extension ContentView {
    var toolbar: some View {
        HStack(spacing: 6) {
            // 左侧只放对归档的动作：打开 / 解压 / 新建。
            // 布局开关（目录栏、详情栏、视图）统一挪到右边，
            // 否则「这一栏显示什么」和「对这个包做什么」混在一排里，主次分不出来。
            openButton
            extractGroup
            newButton

            groupDivider

            // 暂存区属于「工作台」能力，简化模式只留最常用的打开 / 解压 / 新建
            if !model.isCompactMode {
                stashButton
            }

            Spacer(minLength: 12)

            searchField
            if !model.isCompactMode {
                viewSwitcher
                // 目录树只在有归档时才有内容，没开包时这个开关没有意义
                if model.current != nil {
                    ToolButton(symbol: "sidebar.leading",
                               help: showSidebar ? "隐藏目录栏" : "显示目录栏") {
                        showSidebar.toggle()
                    }
                }
                ToolButton(symbol: "sidebar.right",
                           help: showInspector ? "隐藏详情栏" : "显示详情栏",
                           inactive: model.current == nil) {
                    showInspector.toggle()
                }
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 27, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置（⌘,）")

            overflowMenu
            ToolButton(symbol: model.workspaceMode.toggleSymbol,
                       help: model.workspaceMode.toggleHelp,
                       inactive: model.current == nil) {
                model.toggleWorkspaceMode()
                applyModeWindowSize()
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.toolbarHeight)
        .background(Palette.chrome)
    }

    /// 首页的主操作已经是页面里那张卡片，工具栏不再用品牌色重复强调；
    /// 打开归档之后它退成图标，把唯一的品牌色留给「解压」。
    @ViewBuilder
    var openButton: some View {
        if model.current == nil {
            Button {
                model.openWithPanel()
            } label: {
                Label("打开", systemImage: "folder")
                    .font(TypeScale.bodySmall.weight(.medium))
            }
            .buttonStyle(.bordered)
            .help("打开压缩包（⌘O）")
        } else {
            ToolButton(symbol: "folder", help: "打开压缩包（⌘O）") {
                model.openWithPanel()
            }
        }
    }

    /// 解压：有选中解选中、没选中解全部；旁边的小三角给出明确范围。
    /// 没有归档时留一个禁用图标，既不可误触，也不占一整块横向空间。
    @ViewBuilder
    var extractGroup: some View {
        if model.current == nil {
            ToolButton(symbol: "tray.and.arrow.down",
                       help: "先打开一个压缩包",
                       inactive: true) {}
        } else {
            HStack(spacing: 0) {
                Button {
                    if model.selection.isEmpty { model.extractAll() } else { model.extractSelection() }
                } label: {
                    Label("解压", systemImage: "tray.and.arrow.down")
                        .font(TypeScale.bodySmall.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.brand)
                .help(model.selection.isEmpty ? "全部解压（⌘E）" : "解压选中的 \(model.selection.count) 项（⇧⌘E）")

                Menu {
                    Button("全部解压") { model.extractAll() }
                    Button("只解压选中项") { model.extractSelection() }
                        .disabled(model.selection.isEmpty)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Palette.brand)
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("选择解压范围")
            }
        }
    }

    var newButton: some View {
        Button {
            model.createArchive()
        } label: {
            Label("新建", systemImage: "archivebox")
                .font(TypeScale.bodySmall.weight(.medium))
        }
        .buttonStyle(.bordered)
        .help("新建压缩包（⌘N）")
    }

    var groupDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.6))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    var stashButton: some View {
        Button {
            model.isStashVisible.toggle()
        } label: {
            Image(systemName: model.stash.isEmpty ? "tray" : "tray.full")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(model.isStashVisible ? Palette.brand : Color.primary.opacity(0.82))
                .frame(width: 27, height: 24)
                .overlay(alignment: .topTrailing) {
                    if !model.stash.isEmpty {
                        Text("\(model.stash.count)")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Palette.brand, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 4, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(model.current == nil)
        .opacity(model.current == nil ? 0.32 : 1)
        .help("暂存区：把选中项攒起来，跨目录跨包一起导出")
    }

    var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索包内文件", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($searchFocused)
                .frame(width: 128)
                .disabled(model.current == nil)
                .onExitCommand { model.searchText = "" }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Palette.field, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(searchFocused ? Palette.brand.opacity(0.55) : Color.primary.opacity(0.06),
                              lineWidth: 1)
        )
        .help("搜索包内文件（⌘F）")
    }

    var viewSwitcher: some View {
        HStack(spacing: 1) {
            ForEach(ArchiveViewMode.allCases) { mode in
                Button {
                    model.viewMode = mode
                } label: {
                    Image(systemName: mode.symbol)
                        .font(TypeScale.label.weight(.medium))
                        .foregroundStyle(model.viewMode == mode ? Color.primary : Color.secondary)
                        .frame(width: 24, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(model.viewMode == mode ? Color.primary.opacity(0.10) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    var overflowMenu: some View {
        Menu {
            // 全局项（外观、工作模式）在没有打开压缩包时也要能用，
            // 所以菜单本身不再整体禁用，只禁用依赖当前包的动作
            Button("在访达中显示") { model.revealInFinder() }
                .disabled(model.current == nil)
            Button("检查完整性") { model.verifyCurrent() }
                .disabled(model.current == nil)
            if model.isEncrypted { Button("锁定并清除密码") { model.lockCurrent() } }
            Divider()
            Button("添加文件…") { model.addFiles() }
                .disabled(model.current == nil || model.isNested)
            Button("删除选中项…") { model.deleteSelection() }
                .disabled(model.current == nil || model.selection.isEmpty || model.isNested)
            Divider()
            Picker("外观", selection: $model.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            Toggle("窗口变窄时自动简化", isOn: $autoWorkspaceMode)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .regular))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .fixedSize()
        .help("更多操作与外观")
    }

    // MARK: 面包屑

}
