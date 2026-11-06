// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  FinderSync.swift
//  访达右键菜单。菜单内容由 FinderMenuBuilder 决定，执行交给 FinderJobRunner。
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
        // 沙盒扩展压不了 7Z（没有 7zz），这一项直接不摆出来
        let config = FinderSettings.load()
        let actions = config.filtered(
            FinderMenuBuilder.actions(for: selection, canCreate7z: SevenZip.isAvailable))
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

    // MARK: - 解压

    @objc private func extractHere() {
        startExtraction(mode: .here, op: "extractHere")
    }

    @objc private func extractToFolder() {
        startExtraction(mode: .newFolder, op: "extractToFolder")
    }

    private func startExtraction(mode: FinderSettings.ExtractStrategy, op: String) {
        let archives = FinderSelection.inspect(selected).archives
        guard !archives.isEmpty else { return }
        let app = appURL

        // 选择必须在主线程拿完；解压本身放到后台，右键菜单不能卡住
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let outcome = FinderJobRunner.extract(archives, mode: mode)
            FinderJobLog.append(.init(id: UUID().uuidString,
                                      op: op,
                                      startedAt: started,
                                      finishedAt: Date(),
                                      payload: .init(succeeded: outcome.succeeded,
                                                     failed: outcome.failed.map(\.name),
                                                     needsPassword: outcome.needsPassword,
                                                     skippedFiles: outcome.skippedFiles,
                                                     destination: outcome.destination?.path)))

            // 加密包：扩展发不出用户通知（appex 没这个权限），
            // 与其静默失败，不如把包交给主程序——用户本来也要在那里输密码。
            // 顺手把「本来要解到哪」记下来，解锁后主程序接着解，不让这次点击白费。
            if !outcome.needsPassword.isEmpty {
                let locked = archives.filter {
                    outcome.needsPassword.contains($0.lastPathComponent)
                }
                PendingExtraction.write(archives: locked,
                                        mode: mode == .here ? .here : .newFolder)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(locked, withApplicationAt: app,
                                            configuration: NSWorkspace.OpenConfiguration())
                }
                return
            }

            // 「解压到此处」的产物就是当前目录，跳过去没意义，只发通知
            FinderNotifier.report(outcome, verb: "解压",
                                  reveal: mode == .newFolder ? outcome.destination : nil)
        }
    }

    // MARK: - 压缩

    @objc private func compressZip() {
        startCompression(format: .zip, each: false, op: "compressZip")
    }

    @objc private func compressSevenZip() {
        startCompression(format: .sevenZip, each: false, op: "compressSevenZip")
    }

    @objc private func compressEach() {
        startCompression(format: .zip, each: true, op: "compressEach")
    }

    private func startCompression(format: FinderJobRunner.CompressionFormat,
                                  each: Bool, op: String) {
        let urls = FinderSelection.inspect(selected).plain
        guard !urls.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let outcome = FinderJobRunner.compress(urls, format: format, each: each)
            FinderJobLog.append(.init(id: UUID().uuidString,
                                      op: op,
                                      startedAt: started,
                                      finishedAt: Date(),
                                      payload: .init(succeeded: outcome.succeeded,
                                                     failed: outcome.failed.map(\.name),
                                                     needsPassword: outcome.needsPassword,
                                                     skippedFiles: outcome.skippedFiles,
                                                     destination: outcome.destination?.path)))
            FinderNotifier.report(outcome, verb: "压缩", reveal: outcome.destination)
        }
    }
}
