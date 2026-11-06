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
@preconcurrency import UserNotifications

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
                .tabItem { Label("访达与预览", systemImage: "square.on.square") }
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
    @State private var finderInstalled = false
    @State private var settings = FinderSettings.load()
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var confirmRestartFinder = false

    var body: some View {
        Form {
            Section("快速查看") {
                statusRow(ok: quickLookInstalled,
                          okText: "扩展已内置，按空格即可看包内条目",
                          badText: "未找到扩展，重新构建应用可恢复")
                Button("打开「登录项与扩展」设置") { openExtensionSettings() }
                    .controlSize(.small)
                Text("若空格仍无反应：系统设置 → 通用 → 登录项与扩展 → 快速查看，勾选 rrzip。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("访达右键") {
                statusRow(ok: finderInstalled,
                          okText: "访达扩展已随应用安装",
                          badText: "未找到访达扩展，重新构建应用可恢复")
                Text("系统设置 → 通用 → 登录项与扩展 → 访达扩展，勾选 rrzip。这里判断不了你有没有勾——macOS 没有公开接口，所以只给步骤，不做假状态灯。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Space.m) {
                    Button("打开「登录项与扩展」") { openExtensionSettings() }
                    Button("重新启动访达") { confirmRestartFinder = true }
                    Spacer()
                }
                .controlSize(.small)
            }

            Section("右键菜单") {
                Toggle("放进 rrzip 二级菜单", isOn: $settings.secondLevel)
                ForEach(FinderAction.allCases, id: \.self) { action in
                    Toggle(action.title, isOn: binding(for: action))
                        .disabled(action == .compressSevenZip)
                }
                Text("访达扩展是沙盒进程，压不了 7Z（用不了包内 7zz），这一项先在右键里停用；7Z 请在主程序里新建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("其余项改动后需重启访达生效；全部关掉就不显示菜单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("解压位置") {
                Picker("解压到", selection: $settings.extractStrategy) {
                    Text("「包名」文件夹").tag(FinderSettings.ExtractStrategy.newFolder)
                    Text("压缩包所在目录").tag(FinderSettings.ExtractStrategy.here)
                }
                .pickerStyle(.segmented)
                Text("同名文件一律跳过，不会覆盖；重名文件夹自动加序号。加密包只提示，不解压。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通知") {
                HStack(spacing: 8) {
                    Image(systemName: notificationIcon)
                        .foregroundStyle(notificationColor)
                    Text(notificationText)
                        .font(TypeScale.bodySmall)
                    Spacer()
                    switch notificationStatus {
                    case .notDetermined:
                        Button("请求权限") { requestNotifications() }
                            .controlSize(.small)
                    case .denied:
                        Button("打开通知设置") { openNotificationSettings() }
                            .controlSize(.small)
                    default:
                        EmptyView()
                    }
                }
                Text("访达右键任务完成后靠通知汇报结果。扩展自己申请不了授权，只能由这里申请一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: settings) { _, newValue in FinderSettingsStore.save(newValue) }
        .alert("重新启动访达？", isPresented: $confirmRestartFinder) {
            Button("取消", role: .cancel) {}
            Button("重启", role: .destructive) { restartFinder() }
        } message: {
            Text("访达会关闭并重新打开，已打开的窗口会被恢复。")
        }
    }

    // MARK: 状态

    private var notificationIcon: String {
        switch notificationStatus {
        case .authorized, .provisional: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var notificationColor: Color {
        switch notificationStatus {
        case .authorized, .provisional: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private var notificationText: String {
        switch notificationStatus {
        case .authorized: return "已授权，任务完成会发通知"
        case .provisional: return "临时授权，通知会静默投递"
        case .denied: return "已拒绝，任务照常完成但不会提示"
        case .notDetermined: return "还没询问过"
        @unknown default: return "状态未知"
        }
    }

    @ViewBuilder
    private func statusRow(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(ok ? okText : badText)
                .font(TypeScale.bodySmall)
        }
    }

    private func binding(for action: FinderAction) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(action) },
            set: { settings.setEnabled(action, $0) }
        )
    }

    // MARK: 动作

    private func refresh() {
        let plugins = Bundle.main.builtInPlugInsURL
        let fm = FileManager.default
        if let url = plugins?.appendingPathComponent("ArchivePreview.appex") {
            quickLookInstalled = fm.fileExists(atPath: url.path)
        }
        if let url = plugins?.appendingPathComponent("ArchiveFinder.appex") {
            finderInstalled = fm.fileExists(atPath: url.path)
        }
        settings = FinderSettings.load()

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { notificationStatus = status }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                DispatchQueue.main.async { refresh() }
            }
    }

    private func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
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

    private func openNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
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
