// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  SettingsView.swift
//  rrzip
//
//  独立设置中心（⌘,）。每项都对应真实行为，不放没有实现的开关。
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ArchiveModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            CreateSettingsView()
                .tabItem { Label("压缩", systemImage: "archivebox") }
            ExtractSettingsView(model: model)
                .tabItem { Label("解压", systemImage: "tray.and.arrow.down") }
            IntegrationSettingsView()
                .tabItem { Label("Finder 与预览", systemImage: "square.on.square") }
            AdvancedSettingsView(model: model)
                .tabItem { Label("高级", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 600)
        // 设置窗口跟主窗口一个外观，不要一个浅色一个深色
        .preferredColorScheme(model.appearance.scheme)
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    @ObservedObject var model: ArchiveModel
    @AppStorage("rrzip.autoWorkspaceMode") private var autoMode = true
    @AppStorage("rrzip.showSidebar") private var showSidebar = true
    @AppStorage("rrzip.showInspector") private var showInspector = true

    var body: some View {
        Form {
            Section("启动与窗口") {
                Picker("工作模式", selection: $model.workspaceMode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("改这里会立即切换当前窗口；下次启动沿用这个模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("窗口变窄时自动切换模式", isOn: $autoMode)
                Text("阈值跟着三栏宽度走，不写死数字；手动切换后 5 分钟内不再自动切换，避免来回弹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外观") {
                Picker("主题", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Picker("默认视图", selection: $model.viewMode) {
                    ForEach(ArchiveViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("简化模式固定用列表；这里是展开成完整模式后的初始视图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("完整模式的侧栏") {
                Toggle("显示目录栏", isOn: $showSidebar)
                Toggle("显示详情栏", isOn: $showInspector)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 压缩

private struct CreateSettingsView: View {
    @AppStorage("rrzip.defaultCreateFormat") private var formatRaw = CreateFormat.zip.rawValue

    var body: some View {
        Form {
            Section("默认格式") {
                Picker("新建压缩包时预选", selection: $formatRaw) {
                    ForEach(CreateFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                Text("新建时仍可在选项面板里改。TAR / TAR.GZ 本身不支持密码与分卷。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 解压

private struct ExtractSettingsView: View {
    @ObservedObject var model: ArchiveModel
    /// 空串 = 每次询问
    @AppStorage("rrzip.extractDestination") private var destination = ""
    @AppStorage("rrzip.revealAfterExtract") private var revealAfterExtract = true

    private var askEveryTime: Binding<Bool> {
        Binding(
            get: { destination.isEmpty },
            set: { ask in
                if ask {
                    destination = ""
                } else if destination.isEmpty {
                    // 关掉「每次询问」时给一个明确默认，别把用户扔在空状态
                    destination = FileManager.default.urls(for: .downloadsDirectory,
                                                           in: .userDomainMask)[0].path
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("解压位置") {
                Toggle("每次询问解压位置", isOn: askEveryTime)
                if !destination.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(destination)
                            .font(TypeScale.mono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button("更改…") { pickDestination() }
                            .controlSize(.small)
                    }
                }
                Text("选择固定目录后，⌘E 与「解压到文件夹…」不再弹面板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("完成后") {
                Toggle("在访达中显示解压结果", isOn: $revealAfterExtract)
            }

            Section("暂存区导出") {
                Picker("同名文件怎么放", selection: $model.stashLayout) {
                    ForEach(StashLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                Text(model.stashLayout.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选用此目录"
        panel.message = "选择默认的解压目标文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
        }
    }
}

// MARK: - Finder 与预览

private struct IntegrationSettingsView: View {
    @State private var quickLookInstalled = false

    var body: some View {
        Form {
            Section("快速查看") {
                HStack(spacing: 8) {
                    Image(systemName: quickLookInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(quickLookInstalled ? Color.green : Color.orange)
                    Text(quickLookInstalled ? "扩展已内置，按空格即可看包内条目" : "未找到扩展，重新构建应用可恢复")
                        .font(TypeScale.bodySmall)
                }
                Button("打开「登录项与扩展」设置") { openExtensionSettings() }
                    .controlSize(.small)
                Text("若空格仍无反应：系统设置 → 通用 → 登录项与扩展 → 快速查看，勾选 rrzip。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("访达右键") {
                Text("已注册「用 rrzip 压缩」与「用 rrzip 打开」。在访达右键 → 服务 里使用。")
                    .font(TypeScale.bodySmall)
                Button("打开「键盘快捷键 → 服务」设置") { openServicesSettings() }
                    .controlSize(.small)
                Text("找不到时，在服务列表里勾选一次即可常驻。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let appex = Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("ArchivePreview.appex")
            quickLookInstalled = appex.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    private func openExtensionSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    private func openServicesSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences"
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - 高级

private struct AdvancedSettingsView: View {
    @ObservedObject var model: ArchiveModel
    @State private var cacheSize: String = "—"
    @State private var cleared = false

    var body: some View {
        Form {
            Section("缓存与临时文件") {
                HStack {
                    Text("占用")
                    Spacer()
                    Text(cacheSize)
                        .font(TypeScale.data())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("清理缓存") { clear() }
                        .controlSize(.small)
                    if cleared {
                        Text("已清理")
                            .font(TypeScale.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("缩略图、预览解出的临时副本都在这里，清理不影响任何压缩包。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(Self.version)
                        .font(TypeScale.data())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("许可")
                    Spacer()
                    Text("GPL-3.0")
                        .font(TypeScale.data())
                        .foregroundStyle(.secondary)
                }
                Button("查看版本说明") { openReleaseNotes() }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshSize() }
    }

    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func refreshSize() {
        cacheSize = ByteFormatter.string(model.cacheSizeOnDisk())
    }

    private func clear() {
        model.clearCaches()
        cleared = true
        refreshSize()
    }

    private func openReleaseNotes() {
        let local = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/RELEASE_NOTES.md")
        if FileManager.default.fileExists(atPath: local.path) {
            NSWorkspace.shared.open(local)
        } else if let remote = URL(string: "https://github.com/easonwong2026-del/rrzip/releases") {
            NSWorkspace.shared.open(remote)
        }
    }
}
