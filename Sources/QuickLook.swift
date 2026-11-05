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

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    func toggle(entry: ArchiveEntry?, model: ArchiveModel) {
        if isVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
            return
        }
        guard let entry, !entry.isDirectory else { return }

        model.payloadURL(for: entry) { [weak self] url in
            guard let self, let url else { return }
            self.previewURL = url
            guard let panel = QLPreviewPanel.shared() else {
                NSWorkspace.shared.open(url)      // 兜底：交给系统默认程序
                return
            }
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
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
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}
