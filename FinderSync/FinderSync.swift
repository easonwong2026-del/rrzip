// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  FinderSync.swift
//  访达右键菜单。压缩与解压请求投递给主程序。
//  这里只做三件事：建菜单、取选择、把任务丢到后台。
//

import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {

    /// appex 在 app/Contents/PlugIns/…，往上三层就是 .app
    private var appURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override init() {
        super.init()
        // 整个磁盘都挂菜单，比只挂用户目录更省事
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // 空白处右键没有选择项，不占位
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = selected
        guard !urls.isEmpty else { return nil }

        let selection = FinderSelection.inspect(urls)
        // 设置里勾掉的项不出现；全关掉就连菜单一起不显示。
        // 归档引擎由主程序提供，包括 7-Zip。
        let config = FinderSettings.load()
        let actions = config.filtered(
            FinderMenuBuilder.actions(for: selection, canCreate7z: true))
        let note = FinderMenuBuilder.unsupportedNote(for: selection)
        guard !actions.isEmpty || note != nil else { return nil }

        let root = NSMenu(title: "rrzip")
        // 默认收进 rrzip 二级菜单，不污染访达右键一级；设置里可以改成直接展开
        let host: NSMenu
        if config.secondLevel {
            let parent = NSMenuItem(title: "rrzip", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "rrzip")
            parent.submenu = submenu
            root.addItem(parent)
            host = submenu
        } else {
            host = root
        }

        for action in actions {
            let item = NSMenuItem(title: FinderMenuBuilder.title(for: action, in: selection),
                                  action: selector(for: action), keyEquivalent: "")
            item.target = self
            host.addItem(item)
        }
        if let note {
            if !actions.isEmpty { host.addItem(.separator()) }
            let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            item.isEnabled = false
            host.addItem(item)
        }
        return root
    }

    private func selector(for action: FinderAction) -> Selector {
        switch action {
        case .open: return #selector(openSelection)
        case .extractHere: return #selector(extractHere)
        case .extractToFolder: return #selector(extractToFolder)
        case .compressZip: return #selector(compressZip)
        case .compressSevenZip: return #selector(compressSevenZip)
        case .compressEach: return #selector(compressEach)
        }
    }

    private var selected: [URL] {
        FIFinderSyncController.default().selectedItemURLs() ?? []
    }

    /// 多选时全部交给主程序，由它决定打开第一个并在界面上提示其余未打开。
    /// 认不认得出由 OpenGate 说了算，这里不再有第二份后缀表。
    @objc private func openSelection() {
        let archives = FinderSelection.inspect(selected).archives
        guard !archives.isEmpty else { return }
        NSWorkspace.shared.open(archives, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - 任务投递

    @objc private func extractHere() {
        enqueue(.extractHere, urls: FinderSelection.inspect(selected).archives)
    }

    @objc private func extractToFolder() {
        enqueue(.extractToFolder, urls: FinderSelection.inspect(selected).archives)
    }

    @objc private func compressZip() {
        enqueue(.compressZip, urls: FinderSelection.inspect(selected).plain)
    }

    @objc private func compressSevenZip() {
        enqueue(.compressSevenZip, urls: FinderSelection.inspect(selected).plain)
    }

    @objc private func compressEach() {
        enqueue(.compressEach, urls: FinderSelection.inspect(selected).plain)
    }

    private func enqueue(_ operation: FinderTaskRequest.Operation, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let application = appURL
        DispatchQueue.global(qos: .userInitiated).async {
            let needsAttention: Bool
            do {
                try FinderTaskQueue().enqueueSelection(operation, urls: urls)
                needsAttention = false
            } catch {
                needsAttention = true
                PendingNotice.write(title: "访达\(operation.verb)请求未提交", message: error.localizedDescription)
            }
            DispatchQueue.main.async {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = needsAttention
                NSWorkspace.shared.openApplication(at: application, configuration: config) { _, error in
                    if let error {
                        PendingNotice.write(title: "无法唤起 rrzip", message: error.localizedDescription)
                    }
                }
            }
        }
    }
}
