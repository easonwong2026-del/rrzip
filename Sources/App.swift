// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  应用入口与 AppDelegate：打开请求、服务、通知授权、窗口尺寸。

import AppKit
import Carbon
import QuickLook
import SwiftUI
// UNUserNotificationCenter 没标 Sendable，但它的方法本身就是线程安全的；
// 用 @preconcurrency 压掉严格并发下的误报，不绕过检查本身
@preconcurrency import UserNotifications

@main
struct RrzipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if let code = CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(code) }
    }

    var body: some Scene {
        WindowGroup("rrzip", id: MainWindowRecovery.sceneID) {
            ArchiveWindow()
        }
        .defaultSize(width: 720, height: 520)
        .commands { ArchiveCommands() }

        Settings {
            SettingsView(model: AppDelegate.sessions.activeModel ?? AppDelegate.settingsModel)
                .background(WindowRegistration(model: nil))
        }
    }
}

private struct ArchiveWindow: View {
    @State private var model = AppDelegate.sessions.makeModel()

    var body: some View {
        ContentView(model: model)
            .background(WindowRegistration(model: model))
            .frame(minWidth: Layout.minWindowWidth, minHeight: Layout.minWindowHeight)
            .navigationTitle(model.rootArchive?.lastPathComponent ?? "rrzip")
            .focusedSceneValue(\.archiveModel, model)
    }
}

private struct ArchiveModelFocusKey: FocusedValueKey {
    typealias Value = ArchiveModel
}

private extension FocusedValues {
    var archiveModel: ArchiveModel? {
        get { self[ArchiveModelFocusKey.self] }
        set { self[ArchiveModelFocusKey.self] = newValue }
    }
}

private struct ArchiveCommands: Commands {
    @FocusedValue(\.archiveModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") { openWindow(id: MainWindowRecovery.sceneID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("打开压缩包…") { (model ?? AppDelegate.settingsModel).openWithPanel() }
                .keyboardShortcut("o")
            Button("新建压缩包…") { model?.createArchive() }
                .keyboardShortcut("n")
                .disabled(model == nil)
            Divider()
            Button("全部解压…") { model?.extractAll() }
                .keyboardShortcut("e")
                .disabled(model?.current == nil)
            Button("解压选中项…") { model?.extractSelection() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.selection.isEmpty != false)
            Divider()
            Button("返回上一级") { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model?.canGoBack != true)
        }
        CommandGroup(after: .pasteboard) {
            Button("搜索包内文件") { post(.rrzipFocusSearch) }
                .keyboardShortcut("f")
                .disabled(model == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("返回上级") { model?.goBack() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model?.canGoBack != true)
            Button("快速查看") {
                if let model { QuickLookController.shared.toggle(entry: model.selectedEntry, model: model) }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model?.selectedEntry == nil)
            Button("加入暂存区") { model?.addSelectionToStash() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model?.selection.isEmpty != false)
            Divider()
            Button("批量处理…") { model?.pickBatch() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("检查当前压缩包") { model?.verifyCurrent() }
                .disabled(model?.current == nil)
            Divider()
            Button(model?.isCompactMode == false ? "收起为简化模式" : "展开为完整模式") {
                post(.rrzipToggleWorkspaceMode)
            }
            .keyboardShortcut("m", modifiers: [.command, .control])
            .disabled(model == nil)
        }
        CommandGroup(replacing: .help) {
            Button("欢迎使用 rrzip") { post(.rrzipShowWelcome) }
                .disabled(model == nil)
        }
    }

    private func post(_ name: Notification.Name) {
        if let model { NotificationCenter.default.post(name: name, object: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let sessions = WindowSessionRegistry()
    static let settingsModel: ArchiveModel = {
        let model = sessions.makeModel()
        model.routeOpen = { urls, _ in open(urls) }
        return model
    }()

    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private static var windows: [UUID: WindowReference] = [:]
    fileprivate static var openMainWindow: (() -> Void)?
    private static var windowRequested = false
    private static var hasRegisteredMainWindow = false
    private static weak var launchedDelegate: AppDelegate?
    private static var handlesLaterFileEvents = false
    private static var pendingOpen: [(url: URL, preferred: UUID?)] = []
    private static var fileEventWindows: Set<UUID> = []
    private static var unassignedFileWindows: Set<UUID> = []
    private static var finderJobID: UUID?
    private static var startupTasksRun = false
    private static var startupWelcomeShown = false
    private static let finderTaskWorker = makeFinderTaskWorker()

    static func takeStartupTasks() -> Bool {
        guard !startupTasksRun else { return false }
        startupTasksRun = true
        return true
    }

    static func claimStartupWelcome() -> Bool {
        guard !startupWelcomeShown else { return false }
        startupWelcomeShown = true
        return true
    }

    static func window(for model: ArchiveModel) -> NSWindow? { windows[model.sessionID]?.window }

    fileprivate static func register(_ model: ArchiveModel, in window: NSWindow) {
        let id = model.sessionID
        guard windows[id]?.window !== window else { return }
        windows[id] = WindowReference(window)
        hasRegisteredMainWindow = true
        if !handlesLaterFileEvents, let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenDocuments) {
            fileEventWindows.insert(id)
        } else {
            windowRequested = false
        }
        sessions.register(model)
        if window.isKeyWindow { sessions.activate(id) }
        model.routeOpen = { urls, source in open(urls, preferred: source.sessionID) }
        model.cancelFinderTask = { finderTaskWorker.cancelCurrent() }

        DispatchQueue.main.async {
            installOpenDocumentHandler()
            drainPendingOpen()
            consumeFinderNotice()
        }
    }

    private static func focus(_ id: UUID) {
        guard let window = windows[id]?.window else { return }
        sessions.activate(id)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private static func visibleSession() -> ArchiveModel? {
        if let active = sessions.activeModel, window(for: active)?.isVisible == true { return active }
        let ordered = NSApp.orderedWindows
        for window in ordered where window.isVisible {
            if let id = windows.first(where: { $0.value.window === window })?.key {
                sessions.activate(id)
                return sessions.model(id)
            }
        }
        return nil
    }

    @discardableResult
    private static func requestWindow() -> Bool {
        if windowRequested { return true }
        guard let openMainWindow else { return false }
        windowRequested = true
        openMainWindow()
        return true
    }

    static func open(_ urls: [URL], preferred: UUID? = nil) {
        guard !urls.isEmpty else { return }
        let archives = urls.filter {
            if case .open = OpenGate.decide($0) { return true }
            return false
        }
        let requested = archives.isEmpty ? Array(urls.prefix(1)) : archives
        pendingOpen += requested.map { ($0, preferred) }
        drainPendingOpen()
    }

    private static func drainPendingOpen() {
        guard hasRegisteredMainWindow, FormalWriteLedger.shared.currentGate == .idle else { return }
        while let next = pendingOpen.first {
            if case .open = OpenGate.decide(next.url) {
                switch sessions.route(next.url, preferred: next.preferred, newlyCreated: unassignedFileWindows) {
                case .focus(let id):
                    focus(id)
                case .reuse(let id):
                    unassignedFileWindows.remove(id)
                    sessions.model(id)?.openInSession(next.url)
                    focus(id)
                case .newWindow:
                    requestWindow()
                    return
                }
            } else if let model = sessions.activeModel {
                unassignedFileWindows.remove(model.sessionID)
                model.openInSession(next.url)
                focus(model.sessionID)
            } else {
                requestWindow()
                return
            }
            pendingOpen.removeFirst()
        }
        let unused = unassignedFileWindows
        unassignedFileWindows.removeAll()
        for id in unused where sessions.model(id)?.canReuseWindow == true {
            windows[id]?.window?.close()
        }
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = Self.windows.first(where: { $0.value.window === window })?.key else { return }
        Self.sessions.activate(id)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = Self.windows.first(where: { $0.value.window === window })?.key else { return }
        if let model = Self.sessions.model(id) { QuickLookController.shared.close(for: model) }
        Self.windows.removeValue(forKey: id)
        Self.fileEventWindows.remove(id)
        Self.unassignedFileWindows.remove(id)
        Self.sessions.unregister(id)
        if window.isKeyWindow {
            DispatchQueue.main.async {
                guard NSApp.isActive, NSApp.keyWindow == nil, let model = Self.visibleSession() else { return }
                Self.focus(model.sessionID)
            }
        }
    }

    private static func askFinderPassword(for url: URL, wrong: Bool) async -> String? {
        guard !Task.isCancelled else { return nil }
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            let gate = FormalWriteLedger.shared.currentGate
            guard !Task.isCancelled, gate != .cancelling, gate != .terminating else { return nil }
            if let model = visibleSession() {
                focus(model.sessionID)
                return await model.askPassword(for: url, wrong: wrong)
            }
            requestWindow()
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return nil }
        }
        sessions.activeModel?.notice = "无法打开窗口输入访达任务密码"
        return nil
    }

    private static func updateFinderActivity(_ job: TaskJob?) {
        let starting = job != nil && finderJobID != job?.id
        finderJobID = job?.id
        if starting, visibleSession() == nil, FormalWriteLedger.shared.currentGate == .idle {
            requestWindow()
        }
        sessions.showFinderJob(job)
    }

    private static func makeFinderTaskWorker() -> FinderTaskWorker {
        let root = SharedPaths.support.appendingPathComponent("finder-queue", isDirectory: true)
        return FinderTaskWorker(
            queue: FinderTaskQueue(root: root),
            ledger: FormalWriteLedger.shared,
            askPassword: askFinderPassword,
            feedback: { receipt, outcome, operation in
                if receipt.state != .running, let message = receipt.message {
                    sessions.activeModel?.notice = message
                }
                if receipt.state == .succeeded || receipt.state == .failed {
                    FinderNotifier.report(outcome, verb: operation.verb,
                                          reveal: operation == .extractHere ? nil : outcome.outputs.first)
                }
            },
            activity: updateFinderActivity,
            onError: { error in sessions.activeModel?.notice = "访达任务队列：\(error.localizedDescription)" },
            log: { FinderJobLog.append($0) }
        )
    }

    private static func consumeFinderNotice() {
        guard let model = sessions.activeModel, let notice = PendingNotice.take() else { return }
        model.notice = "\(notice.title) · \(notice.message)"
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        let urls = openDocumentURLs(event)
        guard !urls.isEmpty else { return }
        Self.open(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func installOpenDocumentHandler() {
        // 先让 SwiftUI 建立第一个真正的主窗口，使后续路由始终有可用的 OpenWindowAction。
        guard !handlesLaterFileEvents, hasRegisteredMainWindow, let launchedDelegate else { return }
        NSAppleEventManager.shared().setEventHandler(
            launchedDelegate, andSelector: #selector(handleOpenDocuments(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        handlesLaterFileEvents = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.launchedDelegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        requestNotificationPermissionIfNeeded()
        wireTermination()
        Self.sessions.cancelFinderTask = { AppDelegate.finderTaskWorker.cancelCurrent() }
        TerminationCoordinator.shared.host = Self.sessions
        Self.finderTaskWorker.start()
        DispatchQueue.main.async { Self.installOpenDocumentHandler() }
    }

    /// 退出协调的界面部分：状态机在 TerminationCoordinator，这里只提供
    /// 「弹哪个窗」「怎么回答系统」两件事。
    private func wireTermination() {
        let coordinator = TerminationCoordinator.shared
        coordinator.ask = { [weak self] in
            self?.askTerminationChoice() ?? .keepUsing
        }
        coordinator.onTerminate = {
            // 走 reply 而不是 exit(0)：让 AppKit 正常走完终止流程
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        coordinator.onAbort = {
            NSApp.reply(toApplicationShouldTerminate: false)
            AppDelegate.drainPendingOpen()
        }
        // 原地编辑 / 访达服务结束时立刻叫醒退出协调，不必等下一个轮询周期。
        // 回调用 Task 切回主线程：账本注销可能发生在任意线程。
        FormalWriteLedger.shared.onEmpty {
            Task { @MainActor in
                TerminationCoordinator.shared.noteWorkDrained()
            }
        }
    }

    /// 有任务时的退出确认。默认按钮是「等待完成后退出」，
    /// Esc 落在「继续使用」——误触不该把正在跑的任务取消掉。
    private func askTerminationChoice() -> TerminationCoordinator.Choice {
#if DEBUG
        // 本机冒烟：无人值守时用配置项代替点按钮，验证「等待 / 取消 / 继续」三条路
        switch UserDefaults.standard.string(forKey: "rrzip.smokeTerminationChoice") {
        case "wait": return .waitForCompletion
        case "cancel": return .cancelAndQuit
        case "keep": return .keepUsing
        default: break
        }
#endif
        let alert = NSAlert()
        alert.messageText = "仍有任务正在运行"
        alert.informativeText = TerminationCoordinator.shared.workload.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "等待完成后退出")
        alert.addButton(withTitle: "取消任务并退出")
        alert.addButton(withTitle: "继续使用")
        // NSAlert 的第一个按钮本来就是默认键；显式写出来免得以后调顺序踩坑
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .waitForCompletion
        case .alertSecondButtonReturn: return .cancelAndQuit
        default: return .keepUsing
        }
    }

    /// ⌘Q / 菜单退出的唯一入口。
    /// - 没任务：放行，系统立刻退出。
    /// - 有任务：先挂住（terminateLater），弹窗问完、队列收尾后再 reply。
    ///   连续按 ⌘Q 只会走到状态机里已有的那一次，不会重复弹窗。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard TerminationCoordinator.shared.requestTermination() == .terminateNow else { return .terminateLater }
        FormalWriteLedger.shared.setGate(.terminating)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.finderTaskWorker.stopWatching()
    }

    /// 激活时补扫队列，也取旧版扩展可能留下的通知。
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.finderTaskWorker.start()
        Self.consumeFinderNotice()
    }

    /// 访达扩展只能投递通知、不能申请授权，所以授权这件事只能由主程序做。
    /// 晚 2.5 秒，避开首帧窗口与首次引导。
    func requestNotificationPermissionIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else { return }
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    // MARK: - 访达右键「服务」

    /// 用 rrzip 打开
    @objc func openWithRrzip(_ pboard: NSPasteboard, userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard)
        guard !urls.isEmpty else { return }
        // 与 application(_:open:) 同一条判定，不在这里另设后缀白名单
        AppDelegate.open(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 用 rrzip 压缩：在源文件旁边生成同名 zip。
    ///
    /// 交给 `FinderService` 而不是在这里同步跑：服务回调占着主线程，压大目录时
    /// 界面整个卡住，⌘Q 也点不动——而且它写的是用户目录，必须计入正式写入。
    @objc func compressWithRrzip(_ pboard: NSPasteboard, userData: String,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard)
        guard !urls.isEmpty else { return }
        let task = FinderService.compressMerged(urls)
        Task { @MainActor in
            let result = await task.value
            // 退出流程已接管：这次请求根本没执行，不弹窗、不报错
            guard !result.rejected else { return }
            if let output = result.output {
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } else {
                let alert = NSAlert()
                alert.messageText = "压缩失败"
                alert.informativeText = result.failure ?? "未知原因"
                alert.runModal()
            }
        }
    }

    /// 用 rrzip 解压到此处：每个包解到它自己所在的目录。
    /// 走 ServiceExtraction 而不是直接调 ArchiveService.extract——
    /// 后者的默认策略是覆盖，服务入口没有确认界面，不能替用户覆盖同名文件。
    @objc func extractHereWithRrzip(_ pboard: NSPasteboard, userData: String,
                                    error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard).filter { ArchiveService.canOpen($0) }
        guard !urls.isEmpty else { return }
        let task = FinderService.extract(urls)
        Task { @MainActor in
            let outcome = await task.value
            // 退出流程已接管：这次请求根本没执行，不弹窗、不报错
            guard !outcome.rejected else { return }
            let failed = outcome.failed
            if failed.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(
                    urls.map { $0.deletingLastPathComponent() }
                )
            } else {
                let alert = NSAlert()
                alert.messageText = "有 \(failed.count) 个包没能解压"
                alert.informativeText = failed.joined(separator: "\n")
                    + "\n\n加密包需要密码，请用 rrzip 打开后解压。"
                alert.runModal()
            }
        }
    }

    /// 用 rrzip 分别压缩：每个文件各生成一个 zip，不合并
    @objc func compressEachWithRrzip(_ pboard: NSPasteboard, userData: String,
                                     error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = readURLs(from: pboard)
        guard !urls.isEmpty else { return }
        let task = FinderService.compressEach(urls)
        Task { @MainActor in
            let outcome = await task.value
            guard !outcome.rejected else { return }
            if !outcome.made.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(outcome.made)
            }
            // 以前单个失败被 try? 吞掉，界面只显示成功的那几个。
            // 服务入口没有进度，至少要如实说清哪些没成。
            if !outcome.failed.isEmpty {
                let alert = NSAlert()
                alert.messageText = "有 \(outcome.failed.count) 项没能压缩"
                alert.informativeText = outcome.failed.joined(separator: "\n")
                alert.runModal()
            }
        }
    }

    func readURLs(from pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        let created = Self.fileEventWindows
        Self.fileEventWindows.removeAll()
        // AppKit 可能在 didFinishLaunching 前投递首批 URL。等关闭监听接好再回收多余窗口。
        Task { @MainActor in
            AppDelegate.unassignedFileWindows.formUnion(created)
            AppDelegate.open(urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 窗口关掉后再点 Dock 图标，把主窗口找回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Self.visibleSession() != nil { return true }
        if let model = Self.sessions.activeModel, Self.window(for: model)?.isMiniaturized == true {
            Self.focus(model.sessionID)
            return false
        }
        return !Self.hasRegisteredMainWindow || !Self.requestWindow()
    }
}

// MARK: - 主界面

extension Notification.Name {
    /// ⌘F：把焦点丢进搜索框（菜单项发、主界面收）
    static let rrzipFocusSearch = Notification.Name("rrzipFocusSearch")
    /// 反向：把键盘交还列表（点中列表行、搜索框里按 Esc / Return 时发）
    static let rrzipFocusList = Notification.Name("rrzipFocusList")
    /// ⌃⌘M：简化 / 完整模式互切（菜单项发、主界面收，窗口尺寸由主界面负责）
    static let rrzipToggleWorkspaceMode = Notification.Name("rrzipToggleWorkspaceMode")
    /// 帮助菜单：随时重看首次启动那一屏
    static let rrzipShowWelcome = Notification.Name("rrzipShowWelcome")
}


// 窗口通过自身的 AppKit 原生句柄登记，避免迟到的布局回调改到别的窗口。
private struct WindowRegistration: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    let model: ArchiveModel?

    final class WindowView: NSView {
        weak var model: ArchiveModel?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if window.identifier == nil {
                let id = model == nil ? MainWindowRecovery.settingsID : MainWindowRecovery.mainID
                window.identifier = NSUserInterfaceItemIdentifier(id)
            }
            if let model {
                window.tabbingMode = .disallowed
                AppDelegate.register(model, in: window)
            }
        }
    }

    func makeNSView(context: Context) -> WindowView {
        let action = openWindow
        AppDelegate.openMainWindow = { action(id: MainWindowRecovery.sceneID) }
        let view = WindowView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}
}
