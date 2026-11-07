// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  主界面骨架。子视图按功能拆在 MainToolbar / Chrome / EntryList /
//  DetailPane / SidebarPane 里，这里只留状态与布局。

import AppKit
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
// UNUserNotificationCenter 没标 Sendable，但它的方法本身就是线程安全的；
// 用 @preconcurrency 压掉严格并发下的误报，不绕过检查本身
@preconcurrency import UserNotifications

struct ContentView: View {
    @ObservedObject var model: ArchiveModel
    @StateObject var hover = HoverCoordinator()
    @FocusState var listFocused: Bool
    @FocusState var searchFocused: Bool
    @State var stashTargeted = false
    @State var isDropTarget = false
    /// 左右两栏的显隐，跟 viewMode 一样记住用户上次的选择
    @AppStorage("rrzip.showSidebar") var showSidebar = true
    @AppStorage("rrzip.showInspector") var showInspector = true
    /// 窗口变窄自动进简化模式。手动切过之后有冷却期，见 ArchiveModel.autoMode
    @AppStorage("rrzip.autoWorkspaceMode") var autoWorkspaceMode = true
    @State var windowWidth: Double = 1180
    /// 宽度变化的防抖任务：拖动过程中只认最后一次
    @State var autoModeTask: Task<Void, Never>?
    /// 启动阶段先按记住的模式摆好窗口，再让宽度自适应接管，
    /// 否则「上次窗口 1180 宽」会在第一帧把简化模式弹成完整模式
    @State var autoModeReady = false
    /// 首次启动 / 大版本升级时的一屏引导
    @AppStorage("rrzip.welcomeSeenVersion") var welcomeSeenVersion = ""
    @State var showWelcome = false
    /// 密码弹窗的输入框
    @State var passwordInput = ""

    var body: some View {
        shell
            .background(Palette.window)
            .overlay { dropOverlay }
            .overlay(alignment: .bottom) { noticeBar }
            .overlay(alignment: .bottom) { taskOverlay }
            .animation(.easeOut(duration: 0.18), value: model.task?.title)
            .animation(.easeOut(duration: 0.18), value: model.notice)
            .onChange(of: model.notice) { _, newValue in scheduleNoticeClear(newValue) }
            .background(widthReader)
            .onChange(of: windowWidth) { _, width in scheduleModeCheck(width) }
            .preferredColorScheme(model.appearance.scheme)
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { handleDrop($0) }
            .task { await runStartupTasks() }
            .onReceive(NotificationCenter.default.publisher(for: .rrzipFocusSearch)) { _ in
                searchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .rrzipToggleWorkspaceMode)) { _ in
                model.toggleWorkspaceMode()
                applyModeWindowSize()
            }
            .onReceive(NotificationCenter.default.publisher(for: .rrzipShowWelcome)) { _ in
                showWelcome = true
            }
            .onAppear { layoutWindowOnAppear() }
            .sheet(item: $model.batchRequest) { request in
                BatchSheet(urls: request.urls, mode: request.mode)
            }
            .sheet(isPresented: $showWelcome) {
                WelcomeView { remember in
                    if remember { welcomeSeenVersion = WelcomeView.minorVersion(WelcomeView.version) }
                    showWelcome = false
                }
            }
            .alert("出错了", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .background(passwordPrompt)
    }

    // MARK: 拆出来给类型检查减负

    // body 里原先塞着一百多行启动逻辑和一整个 GeometryReader，CI 的编译器会报
    // "unable to type-check this expression in reasonable time"（本地 6.3.3 不报）。
    // 拆成独立成员后每个表达式的深度都降下来了。

    var shell: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            breadcrumbBar
            Hairline()

            if model.current == nil {
                HomeView(model: model)
            } else if model.isCompactMode {
                compactWorkspace
            } else {
                // HSplitView 里条件显隐子视图后，理想宽度会算不准，
                // 必须显式把可用宽高喂给它，否则最右一栏会被窗口裁掉
                GeometryReader { proxy in
                    HSplitView {
                        if showSidebar {
                            sidebar
                                .frame(minWidth: Metrics.sidebarMin, idealWidth: 198, maxWidth: 280)
                        }
                        entryList
                            .frame(minWidth: Metrics.contentMin)
                        if showInspector {
                            detailPane
                                .frame(minWidth: Metrics.inspectorMin, idealWidth: 288, maxWidth: 340)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                // GeometryReader 的理想宽度接近 0，会让窗口被挤到最小宽度，补回理想尺寸
                .frame(idealWidth: 1120, idealHeight: 660)
            }

            if model.isStashVisible {
                Hairline()
                stashBar
            }

            Hairline()
            statusBar
        }
    }

    @ViewBuilder
    var taskOverlay: some View {
        if model.taskVisible, let task = model.task {
            TaskCard(task: task) { model.cancelTask() }
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 量一次窗口宽度：简化 / 完整模式的自动切换只看它，不猜窗口尺寸
    var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { windowWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in windowWidth = width }
        }
    }

    /// 加密包的密码询问。用 SwiftUI alert 而不是 NSAlert.runModal：
    /// 后者在 async 上下文里会跑嵌套 runloop，偶尔根本不显示。
    /// 挂到 background 的隐藏视图上：同一个视图链上两个 .alert 只会生效一个，
    /// 「出错了」那个会把这个吃掉。
    var passwordPrompt: some View {
        Color.clear.alert(model.passwordRequest?.isRetry == true ? "密码不正确" : "该压缩包已加密",
                          isPresented: Binding(
                            get: { model.passwordRequest != nil },
                            set: { if !$0 { model.submitPassword(nil) } }
                          )) {
            TextField("密码", text: $passwordInput)
            Button("解锁") {
                let value = passwordInput
                passwordInput = ""
                model.submitPassword(value.isEmpty ? nil : value)
            }
            Button("取消", role: .cancel) {
                passwordInput = ""
                model.submitPassword(nil)
            }
        } message: {
            Text("\(model.passwordRequest?.archive.lastPathComponent ?? "")\n输入密码后即可浏览与解压。")
        }
    }

    func scheduleNoticeClear(_ newValue: String?) {
        guard let newValue else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 期间又来了新提示就别清，让新提示自己走完
            if model.notice == newValue { model.notice = nil }
        }
    }

    func scheduleModeCheck(_ width: Double) {
        guard autoModeReady, autoWorkspaceMode else { return }
        // 拖动窗口时宽度是连续变化的，合并 100ms 再判定，
        // 否则会在阈值附近反复切模式
        autoModeTask?.cancel()
        autoModeTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            guard let next = model.autoMode(forWidth: width) else { return }
            model.setWorkspaceMode(next, manual: false)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { value, _ in
                        continuation.resume(returning: value)
                    }
                }
                if let url { urls.append(url) }
            }
            if urls.count > 1 {
                model.batchRequest = BatchRequest(urls: urls, mode: .extract)
            } else if let first = urls.first {
                model.open(url: first)
            }
        }
        return true
    }

    func layoutWindowOnAppear() {
        // 首帧按当前模式给窗口尺寸：简化模式退回 720 宽，完整模式补回 1180。
        // 摆好之后再让宽度自适应接管，避免两者抢着改窗口。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            defer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    autoModeReady = true
                }
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 })
            else { return }
            let compact = model.isCompactMode
            // 最小尺寸与模式解耦：完整模式也允许缩到简化尺寸。
            // 旧版在这里把完整模式锁到 1020 宽，而自动收起判据是 < 760，
            // 窗口根本窄不下去，那条分支一整版都没被触发过。
            window.minSize = NSSize(width: Layout.minWindowWidth,
                                   height: Layout.minWindowHeight)
            var frame = window.frame
            if compact {
                // 上次在完整模式留下的宽窗口，进简化模式后收回来
                guard frame.width > 1100 else { return }
                frame.origin.y += frame.height - 520
                frame.size = NSSize(width: 720, height: 520)
            } else {
                guard frame.width < 1100 else { return }
                frame.origin.y += frame.height - 720
                frame.size = NSSize(width: 1180, height: 720)
            }
            window.setFrame(frame, display: true, animate: false)
        }

        // 首次启动（或版本变了）弹一屏说明；等窗口摆好再出，避免和首帧抢
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
#if DEBUG
            if UserDefaults.standard.bool(forKey: "rrzip.showWelcome") {
                UserDefaults.standard.set(false, forKey: "rrzip.showWelcome")
                showWelcome = true
                return
            }
#endif
            guard WelcomeView.minorVersion(welcomeSeenVersion)
                    != WelcomeView.minorVersion(WelcomeView.version) else { return }
            showWelcome = true
        }
    }

    func runStartupTasks() async {
#if DEBUG
        // 排查用：把启动参数落一份，确认 --settings 这类调试开关有没有进来
        try? CommandLine.arguments.joined(separator: " ")
            .write(toFile: "/tmp/rrzip-argv.txt", atomically: true, encoding: .utf8)
        // 便于截图/调试：--icons 初始图标视图，--search xxx 预填搜索
        if CommandLine.arguments.contains("--icons") { model.viewMode = .icons }
        // 便于截图：--compact / --full 指定起始工作模式
        if CommandLine.arguments.contains("--compact") { model.setWorkspaceMode(.compact, manual: false) }
        if CommandLine.arguments.contains("--full") { model.setWorkspaceMode(.full, manual: false) }
        // 便于截图：--settings 直接打开设置窗口
        // （`open --args` 在本机不传参，所以同时支持 defaults 开关）
        if CommandLine.arguments.contains("--settings")
            || UserDefaults.standard.bool(forKey: "rrzip.openSettings") {
            UserDefaults.standard.set(false, forKey: "rrzip.openSettings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.activate(ignoringOtherApps: true)
                // 先把菜单结构写出来，便于确认「设置…」到底在不在
                let dump = (NSApp.mainMenu?.items ?? []).map { item in
                    "\(item.title) -> " + (item.submenu?.items.map(\.title).joined(separator: " | ") ?? "")
                }.joined(separator: "\n")
                try? dump.write(toFile: "/tmp/rrzip-menu.txt", atomically: true, encoding: .utf8)

                var opened = false
                for menu in NSApp.mainMenu?.items ?? [] {
                    guard let submenu = menu.submenu,
                          let item = submenu.items.first(where: {
                              $0.title.contains("设置") || $0.title.contains("Settings")
                          }),
                          let action = item.action else { continue }
                    NSApp.sendAction(action, to: item.target, from: item)
                    opened = true
                    break
                }
                if !opened {
                    _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
            model.searchText = CommandLine.arguments[i + 1]
        }
#endif
#if DEBUG
        // 调试用：defaults write com.rrzip.mac rrzip.batchFiles "a.zip,b.zip"
        if let paths = UserDefaults.standard.string(forKey: "rrzip.batchFiles") {
            let urls = paths.split(separator: ",")
                .map { URL(fileURLWithPath: String($0)) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty {
                let mode: BatchRunner.Mode =
                    UserDefaults.standard.string(forKey: "rrzip.batchMode") == "verify" ? .verify : .extract
                model.batchRequest = BatchRequest(urls: urls, mode: mode)
            }
        }
#endif
        // 支持 `open -a rrzip xxx.zip` 以及命令行直接传路径。
        // 判定走 OpenGate，改过名的包从命令行打开也要能认出来。
        if model.trail.isEmpty {
            for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
                let url = URL(fileURLWithPath: arg)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if case .open = OpenGate.decide(url) {
                    model.open(url: url)
                    break
                }
            }
        }
        // 调试用：跳进某个包内目录（也支持 defaults write com.rrzip.mac rrzip.goto）
#if DEBUG
        let goto = CommandLine.arguments.firstIndex(of: "--goto").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        } ?? UserDefaults.standard.string(forKey: "rrzip.goto")
        if let goto, !goto.isEmpty {
            var waited = 0
            while model.current == nil && waited < 40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                waited += 1
            }
            model.jump(to: goto)
        }
#endif
        // 调试用：直接弹系统快速查看面板
#if DEBUG
        if UserDefaults.standard.bool(forKey: "rrzip.demoQuickLook") {
            var waited = 0
            while model.displayEntries.isEmpty && waited < 40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                waited += 1
            }
            if let first = model.displayEntries.first(where: { !$0.isDirectory }) {
                model.selection = [first.id]
                try? await Task.sleep(nanoseconds: 300_000_000)
                QuickLookController.shared.toggle(entry: first, model: model)
            }
        }
#endif
#if DEBUG
        // 调试用：选中指定条目，便于核对右侧预览
        // defaults write com.rrzip.mac rrzip.select "封面.jpg"
        if let wanted = UserDefaults.standard.string(forKey: "rrzip.select"), !wanted.isEmpty {
            var waited = 0
            while model.displayEntries.isEmpty && waited < 40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                waited += 1
            }
            if let match = model.displayEntries.first(where: { $0.name == wanted })
                ?? model.displayEntries.first(where: { $0.name.contains(wanted) }) {
                model.select(match)
            }
        }
#endif
        // 调试用：把前几个文件放进暂存区，便于截图核对
#if DEBUG
        if UserDefaults.standard.bool(forKey: "rrzip.demoStash") {
            var waited = 0
            while model.displayEntries.isEmpty && waited < 40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                waited += 1
            }
            let targets = model.displayEntries.filter { !$0.isDirectory }.prefix(3)
            model.selection = Set(targets.map(\.id))
            model.addSelectionToStash()
        }
#endif
        // 调试用：--demo-hover 等条目读完弹一次悬停卡片，便于截图核对
#if DEBUG
        if CommandLine.arguments.contains("--demo-hover") || UserDefaults.standard.bool(forKey: "rrzip.demoHover") {
            var waited = 0
            while model.displayEntries.isEmpty && waited < 40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                waited += 1
            }
            if let first = model.displayEntries.first(where: { !$0.isDirectory }) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                hover.begin(first, model: model, at: NSPoint(x: 700, y: 620))
            }
        }
#endif
    }


    // MARK: 窗口尺寸

    /// 手动切换模式时同步窗口尺寸：展开给工作台尺寸，收起给小窗尺寸。
    /// 顶边保持不动，避免窗口在屏幕上跳。
    func applyModeWindowSize() {
        guard let window = NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        else { return }
        let compact = model.isCompactMode
        // 下限恒定，不随模式抬高；抬高就等于禁止用户把完整模式拉窄到自动收起阈值以下
        window.minSize = NSSize(width: Layout.minWindowWidth,
                               height: Layout.minWindowHeight)
        var frame = window.frame
        let target = compact
            ? NSSize(width: 720, height: 520)
            : NSSize(width: max(frame.width, 1180), height: max(frame.height, 720))
        frame.origin.y += frame.height - target.height
        frame.size = target
        window.setFrame(frame, display: true, animate: true)
    }

}
