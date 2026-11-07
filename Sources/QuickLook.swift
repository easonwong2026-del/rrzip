// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import QuickLookUI

/// 空格快速查看：把条目解到临时文件，用系统快速查看面板全屏预览。
/// 面板不可用时退回默认程序打开（预览 / QuickTime）。
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var previewURL: URL?
    /// 面板被系统关掉（Esc 由面板自己处理、点关闭按钮）时也要释放占用，
    /// 不能只指望我们自己的 close()
    private var observingPanel = false

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    /// 面板正显示这个临时文件，清缓存不能把它删掉。
    /// 只 hold 当前这一个：换了或关了立刻释放，不留悬挂引用。
    private func setPreviewURL(_ url: URL?) {
        if let current = previewURL { ScratchUsage.shared.release(current) }
        previewURL = url
        if let url { ScratchUsage.shared.hold(url) }
    }

    /// 面板是共享单例，观察一次就够。
    /// 用 ObjC 原始通知名：这个 SDK 里 NSWindow 没有对应的 Swift 静态常量。
    private func observe(_ panel: QLPreviewPanel) {
        guard !observingPanel else { return }
        observingPanel = true
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.willCloseNotification,
            Notification.Name("NSWindowDidOrderOffScreenNotification")
        ]
        for name in names {
            center.addObserver(self, selector: #selector(panelDidDismiss),
                               name: name, object: panel)
        }
    }

    @objc private func panelDidDismiss() {
        setPreviewURL(nil)
    }

    func toggle(entry: ArchiveEntry?, model: ArchiveModel) {
        if isVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
            setPreviewURL(nil)
            return
        }
        guard let entry, !entry.isDirectory else { return }

        model.payloadURL(for: entry) { [weak self] url in
            guard let self, let url else { return }
            self.setPreviewURL(url)
            guard let panel = QLPreviewPanel.shared() else {
                NSWorkspace.shared.open(url)      // 兜底：交给系统默认程序
                return
            }
            self.observe(panel)
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
        setPreviewURL(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }

    // MARK: - QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false }   // 空格关闭
        MainActor.assumeIsolated { self.close() }
        return true
    }
}
