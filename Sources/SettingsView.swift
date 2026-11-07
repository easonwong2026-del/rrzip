// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  SettingsView.swift
//  rrzip
//
//  独立设置中心（⌘,）。四页：通用 / 文件操作 / 访达与扩展 / 关于与维护。
//
//  设计约束（改动前先看这里）：
//  - 每项都对应真实行为，不放没有实现的开关；验证不了的状态不显示。
//  - 分组名 → 设置项 → 必要时一行说明。技术细节进 footer，不占常驻空间。
//  - 沿用 Palette 的品牌青绿，只用于选中态，不做大面积色块。
//

import AppKit
import SwiftUI
@preconcurrency import UserNotifications

struct SettingsView: View {
    @ObservedObject var model: ArchiveModel
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "通用"
        case files = "文件操作"
        case integration = "访达与扩展"
        case about = "关于与维护"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .files: return "archivebox"
            case .integration: return "square.on.square"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 660 放不下「固定解压目录 + 更改按钮」那一行：路径会被挤成三截。
        // 只加到 680，不为长路径继续加宽（路径本来就中间省略）。
        .frame(width: 680, height: 620)
        // 设置窗口跟主窗口一个外观，不要一个浅色一个深色
        .preferredColorScheme(model.appearance.scheme)
    }

    /// 左栏：选中项是青绿底条，而不是系统 TabView 的顶部标签
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.m) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text("rrzip")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: Space.m) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                        Text(item.rawValue)
                            .font(.system(size: 12.5))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.l)
                    .frame(height: 30)
                    .foregroundStyle(tab == item ? Palette.brand : Color.primary.opacity(0.85))
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tab == item ? Palette.brand.opacity(0.16) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Space.m)
            }

            Spacer()
        }
        .frame(width: 168)
        .background(Palette.chrome)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettingsView(model: model)
        case .files: FilesSettingsView(model: model)
        case .integration: IntegrationSettingsView()
        case .about: AboutSettingsView(model: model)
        }
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
            Section {
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
            } header: {
                Text("外观")
            } footer: {
                Text("默认视图只在完整模式下生效，简化模式固定用列表。")
            }

            Section {
                Picker("默认工作模式", selection: modeBinding) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("随窗口宽度自动切换", isOn: $autoMode)
            } header: {
                Text("工作模式")
            } footer: {
                Text("手动切换后 5 分钟内不会被自动切换改回，再次启动沿用最后选择。")
            }

            Section {
                Toggle("显示目录栏", isOn: $showSidebar)
                Toggle("显示详情栏", isOn: $showInspector)
            } header: {
                Text("窗口布局")
            } footer: {
                Text("仅完整模式，简化模式始终单栏。")
            }
        }
        .formStyle(.grouped)
    }

    /// 设置页选模式必须走 manual 路径，否则冷却期不生效
    /// （见 ArchiveModel.selectWorkspaceModeFromSettings）
    private var modeBinding: Binding<WorkspaceMode> {
        Binding(
            get: { model.workspaceMode },
            set: { model.selectWorkspaceModeFromSettings($0) }
        )
    }
}

// MARK: - 文件操作

private struct FilesSettingsView: View {
    @ObservedObject var model: ArchiveModel
    @AppStorage("rrzip.defaultCreateFormat") private var formatRaw = CreateFormat.zip.rawValue
    /// 空串 = 每次询问
    @AppStorage("rrzip.extractDestination") private var destination = ""
    @AppStorage("rrzip.revealAfterExtract") private var revealAfterExtract = true

    private var askEveryTime: Binding<Bool> {
        Binding(
            get: { destination.isEmpty },
            set: { ask in
                if ask {
                    destination = ""
                } else {
                    // 关掉「每次询问」必须由用户点选目录。
                    // 旧版在这里直接塞了下载目录：用户取消了面板，配置却已经改了，
                    // 下次解压莫名其妙落到「下载」里，还以为是 bug。
                    pickDestination()
                }
            }
        )
    }

    private var resolution: ExtractDestinationSetting.Resolution {
        ExtractDestinationSetting.resolve(destination)
    }

    var body: some View {
        Form {
            Section {
                Picker("默认格式", selection: $formatRaw) {
                    ForEach(CreateFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
            } header: {
                Text("压缩")
            } footer: {
                Text("创建压缩包时仍可修改格式和压缩级别。")
            }

            Section {
                Toggle("每次询问位置", isOn: askEveryTime)

                if !destination.isEmpty {
                    HStack(spacing: Space.m) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(destination)
                            .font(TypeScale.mono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destination)
                        Spacer(minLength: Space.xs)
                        Button("更改…") { pickDestination() }
                            .controlSize(.small)
                    }
                    if let problem = resolution.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(TypeScale.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Toggle("完成后在访达中显示", isOn: $revealAfterExtract)
            } header: {
                Text("解压")
            } footer: {
                Text("选定固定目录后，⌘E 与「解压到文件夹…」不再弹面板。")
            }

            Section {
                Picker("同名文件", selection: $model.stashLayout) {
                    ForEach(StashLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
            } header: {
                Text("暂存区导出")
            } footer: {
                Text(model.stashLayout.detail)
            }
        }
        .formStyle(.grouped)
    }

    /// 面板取消时不动配置：那一次切换就是不生效。
    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选用此目录"
        panel.message = "选择默认的解压目标文件夹"
        if let current = resolution.url { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = ExtractDestinationSetting.store(url.path)
    }
}

// MARK: - 访达与扩展

private struct IntegrationSettingsView: View {
    @State private var quickLookInstalled = false
    @State private var finderInstalled = false
    @State private var settings = FinderSettings.load()
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var confirmRestartFinder = false
    /// 落盘失败必须说出来：以前 try? 吞掉错误，界面照旧显示已勾选，
    /// 用户以为设好了，重启访达发现菜单没变
    @State private var saveFailed = false

    /// 界面上的顺序：先打开与解压，再压缩。
    /// 「压缩为 7Z」不在列表里——沙盒扩展压不了，摆一个灰掉的开关只是噪音；
    /// 旧配置里已有的这一项原样留在 finder.json 里，不删字段。
    private static let openExtractActions: [FinderAction] = [.open, .extractHere, .extractToFolder]
    private static let compressActions: [FinderAction] = [.compressZip, .compressEach]

    var body: some View {
        Form {
            Section {
                extensionRow("访达右键扩展", installed: finderInstalled)
                extensionRow("快速查看扩展", installed: quickLookInstalled)
                HStack(spacing: Space.m) {
                    Text("任务通知")
                    Spacer(minLength: Space.m)
                    Text(notificationText)
                        .foregroundStyle(.secondary)
                    actionButton
                }
                // 三个动作都是「让扩展真正生效」要按的按钮，放在一行里
                HStack(spacing: Space.m) {
                    Button("打开系统扩展设置") { openExtensionSettings() }
                    Button("重新启动访达") { confirmRestartFinder = true }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            } header: {
                Text("扩展与通知")
            } footer: {
                Text("「已安装」只说明扩展随应用构建，是否启用由系统设置决定。改动右键菜单后需重启访达。")
            }

            Section {
                Toggle("收进 rrzip 子菜单", isOn: $settings.secondLevel)
                groupLabel("打开与解压")
                ForEach(Self.openExtractActions, id: \.self) { action in
                    Toggle(action.title, isOn: binding(for: action))
                }
                groupLabel("压缩")
                ForEach(Self.compressActions, id: \.self) { action in
                    Toggle(action.title, isOn: binding(for: action))
                }
            } header: {
                Text("右键菜单")
            } footer: {
                if saveFailed {
                    Label("设置没能写入，重启访达后会回到上一次保存的配置",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("全部关闭则不再显示菜单。7Z 需要主程序内的引擎，右键不提供。")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: settings) { _, newValue in
            saveFailed = !FinderSettingsStore.save(newValue)
        }
        .alert("重新启动访达？", isPresented: $confirmRestartFinder) {
            Button("取消", role: .cancel) {}
            Button("重启", role: .destructive) { restartFinder() }
        } message: {
            Text("访达会关闭并重新打开，已打开的窗口会被恢复。")
        }
    }

    // MARK: 行

    private func extensionRow(_ title: String, installed: Bool) -> some View {
        HStack(spacing: Space.m) {
            Text(title)
            Spacer(minLength: Space.m)
            Text(installed ? "已安装" : "未找到")
                .foregroundStyle(installed ? Color.secondary : Color.orange)
        }
    }

    /// 组内小标题：把「打开与解压」和「压缩」分开，不额外占一个分组的高度
    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(TypeScale.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.xs)
    }

    private var notificationText: String {
        switch notificationStatus {
        case .authorized: return "已授权"
        case .provisional: return "临时授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未询问"
        @unknown default: return "未知"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch notificationStatus {
        case .notDetermined:
            Button("允许通知") { requestNotifications() }
                .controlSize(.small)
        case .denied:
            Button("打开系统设置") { openNotificationSettings() }
                .controlSize(.small)
        default:
            EmptyView()
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
        if let url = plugins?.appendingPathComponent("ArchiveFinder.appex") {
            finderInstalled = fm.fileExists(atPath: url.path)
        }
        if let url = plugins?.appendingPathComponent("ArchivePreview.appex") {
            quickLookInstalled = fm.fileExists(atPath: url.path)
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

// MARK: - 关于与维护

private struct AboutSettingsView: View {
    @ObservedObject var model: ArchiveModel
    @State private var cacheBytes: Int64 = 0
    @State private var cleanupReport: CacheCleanupReport?

    var body: some View {
        Form {
            Section {
                HStack(spacing: Space.xl) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("rrzip")
                            .font(.system(size: 14, weight: .semibold))
                        Text("版本 \(Self.version)")
                            .font(TypeScale.label)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.xxs)
            }

            Section {
                infoRow("版本更新说明", value: "", button: "查看") { openReleaseNotes() }
                infoRow("GitHub 项目", value: "easonwong2026-del/rrzip", button: "打开") {
                    open(URL(string: "https://github.com/easonwong2026-del/rrzip"))
                }
                infoRow("开源许可", value: "GPL-3.0", button: "查看") { openLicense() }
            }

            Section {
                HStack(spacing: Space.m) {
                    Text("占用")
                    Spacer(minLength: Space.m)
                    Text(ByteFormatter.string(cacheBytes))
                        .font(TypeScale.data())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: Space.m) {
                    Button("清理缓存") { clear() }
                        .controlSize(.small)
                    if let report = cleanupReport {
                        Text(report.text)
                            .font(TypeScale.caption)
                            .foregroundStyle(report.succeeded ? Color.secondary : Color.orange)
                    }
                }
            } header: {
                Text("缓存")
            } footer: {
                Text("缩略图与预览解出的临时副本，不影响压缩包和其他文件。")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshSize() }
    }

    // MARK: 行

    private func infoRow(_ title: String, value: String, button: String,
                         action: @escaping () -> Void) -> some View {
        HStack(spacing: Space.m) {
            Text(title)
            Spacer(minLength: Space.m)
            if !value.isEmpty {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(button, action: action)
                .controlSize(.small)
        }
    }

    // MARK: 数据

    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }

    private func refreshSize() {
        cacheBytes = model.cacheSizeOnDisk()
    }

    private func clear() {
        let report = model.clearCaches()
        cleanupReport = report
        refreshSize()
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// 本地 RELEASE_NOTES 优先，没有就跳 Releases 页
    private func openReleaseNotes() {
        let local = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/RELEASE_NOTES.md")
        if FileManager.default.fileExists(atPath: local.path) {
            NSWorkspace.shared.open(local)
        } else {
            open(URL(string: "https://github.com/easonwong2026-del/rrzip/releases"))
        }
    }

    /// 许可全文随应用一起放在 Resources 里；读不到再回退到仓库
    private func openLicense() {
        let local = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/LICENSE")
        if FileManager.default.fileExists(atPath: local.path) {
            NSWorkspace.shared.open(local)
        } else {
            open(URL(string: "https://github.com/easonwong2026-del/rrzip/blob/main/LICENSE"))
        }
    }
}
