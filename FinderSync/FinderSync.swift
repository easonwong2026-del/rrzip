// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  FinderSync.swift
//  访达右键菜单。菜单内容由 FinderMenuBuilder 决定，这里只负责建菜单和干活。
//  动作直接调包内 7zz，不唤起主窗口，省一次进程切换。
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

    private var archiveTool: URL? {
        let tool = appURL.appendingPathComponent("Contents/Resources/7zz")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
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
        let actions = FinderMenuBuilder.actions(for: selection)
        let note = FinderMenuBuilder.unsupportedNote(for: selection)
        guard !actions.isEmpty || note != nil else { return nil }

        let menu = NSMenu(title: "rrzip")
        for action in actions {
            let item = NSMenuItem(title: FinderMenuBuilder.title(for: action, in: selection),
                                  action: selector(for: action), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let note {
            if !actions.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
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
    /// 不再用后缀兜底层——认不认得出由 OpenGate 说了算。
    @objc private func openSelection() {
        let archives = FinderSelection.inspect(selected).archives
        guard !archives.isEmpty else { return }
        NSWorkspace.shared.open(archives, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func extractHere() {
        let archives = FinderSelection.inspect(selected).archives
        for url in archives {
            run(["x", "-y", "-o" + url.deletingLastPathComponent().path, url.path])
        }
    }

    /// 解到「包名」文件夹：目标目录先验重名，再解压，包内不会碰到已有文件
    @objc private func extractToFolder() {
        let archives = FinderSelection.inspect(selected).archives
        for url in archives {
            let folder = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let target = uniqueDirectory(
                folder.appendingPathComponent(base.isEmpty ? "归档" : base, isDirectory: true))
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            run(["x", "-y", "-o" + target.path, url.path])
        }
    }

    @objc private func compressZip() {
        let plain = plainSelection()
        guard !plain.isEmpty else { return }
        let folder = plain[0].deletingLastPathComponent()
        let base = plain.count == 1
            ? plain[0].deletingPathExtension().lastPathComponent
            : folder.lastPathComponent
        let output = uniqueOutput(folder.appendingPathComponent(base.isEmpty ? "归档" : base)
            .appendingPathExtension("zip"))
        run(["a", "-tzip", "-y", output.path] + plain.map(\.path))
    }

    @objc private func compressSevenZip() {
        let plain = plainSelection()
        guard !plain.isEmpty else { return }
        let folder = plain[0].deletingLastPathComponent()
        let base = plain.count == 1
            ? plain[0].deletingPathExtension().lastPathComponent
            : folder.lastPathComponent
        let output = uniqueOutput(folder.appendingPathComponent(base.isEmpty ? "归档" : base)
            .appendingPathExtension("7z"))
        run(["a", "-t7z", "-y", output.path] + plain.map(\.path))
    }

    @objc private func compressEach() {
        for url in plainSelection() {
            let folder = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let output = uniqueOutput(folder.appendingPathComponent(base.isEmpty ? "归档" : base)
                .appendingPathExtension("zip"))
            run(["a", "-tzip", "-y", output.path, url.path])
        }
    }

    /// 参与压缩的普通项目（文件与文件夹），压缩包不参与
    private func plainSelection() -> [URL] {
        FinderSelection.inspect(selected).plain
    }

    /// 同名就加序号，不覆盖。与 ArchiveModel.uniqueOutput 同规则——
    /// 扩展不能链主 target，只能各留一份
    private func uniqueOutput(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// 目录版：不拼扩展名
    private func uniqueDirectory(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        var index = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(index)", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func run(_ arguments: [String]) {
        guard let tool = archiveTool else { return }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        try? process.run()
    }
}
