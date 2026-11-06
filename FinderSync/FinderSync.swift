// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  FinderSync.swift
//  访达右键菜单。动作直接调包内 7zz，不唤起主窗口，省一次进程切换。
//

import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {
    private let archiveExts: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso"
    ]

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
        let menu = NSMenu(title: "rrzip")
        menu.addItem(withTitle: "用 rrzip 打开", action: #selector(openSelection), keyEquivalent: "")
        menu.addItem(withTitle: "解压到此处", action: #selector(extractHere), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "压缩为 ZIP", action: #selector(compressZip), keyEquivalent: "")
        menu.addItem(withTitle: "分别压缩", action: #selector(compressEach), keyEquivalent: "")
        return menu
    }

    private var selected: [URL] {
        FIFinderSyncController.default().selectedItemURLs() ?? []
    }

    private func isArchive(_ url: URL) -> Bool {
        archiveExts.contains(url.pathExtension.lowercased())
    }

    @objc private func openSelection() {
        guard let first = selected.first else { return }
        NSWorkspace.shared.open([first], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func extractHere() {
        let archives = selected.filter(isArchive)
        for url in archives {
            run(["x", "-y", "-o" + url.deletingLastPathComponent().path, url.path])
        }
    }

    @objc private func compressZip() {
        guard let first = selected.first else { return }
        let folder = first.deletingLastPathComponent()
        let base = selected.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : folder.lastPathComponent
        let output = uniqueOutput(folder.appendingPathComponent(base.isEmpty ? "归档" : base)
            .appendingPathExtension("zip"))
        run(["a", "-tzip", "-y", output.path] + selected.map(\.path))
    }

    @objc private func compressEach() {
        for url in selected {
            let folder = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let output = uniqueOutput(folder.appendingPathComponent(base.isEmpty ? "归档" : base)
                .appendingPathExtension("zip"))
            run(["a", "-tzip", "-y", output.path, url.path])
        }
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

    private func run(_ arguments: [String]) {
        guard let tool = archiveTool else { return }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        try? process.run()
    }
}
