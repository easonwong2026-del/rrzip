// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Foundation
import UniformTypeIdentifiers

/// 应用内拖拽使用的自定义类型：暂存区靠它拿到「包 + 包内路径」，不必先解压
let rrzipEntryType = UTType(exportedAs: "com.rrzip.entry")

/// 暂存区里的一条：记住它来自哪个包，才能跨层、跨包累积
struct StashItem: Identifiable, Hashable {
    let id = UUID()
    let archive: URL
    let path: String
    let size: Int64
    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }
    var displaySize: String { ByteFormatter.string(size) }
}

/// 一次暂存导出的结果
struct StashExport {
    let url: URL
    /// 目标已有同名文件，按「不覆盖」跳过了
    let skipped: Bool
}

/// 暂存区导出时的落盘方式：不同包里的同名文件不能互相覆盖
enum StashLayout: String, CaseIterable, Identifiable {
    /// 每个包一个子目录（默认，最不容易撞名）
    case perArchive
    /// 全部平铺，同名自动加序号
    case flat
    /// 保留包内目录结构
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perArchive: return "每个包一个文件夹"
        case .flat: return "全部平铺（同名自动改名）"
        case .original: return "保留包内目录结构"
        }
    }

    var detail: String {
        switch self {
        case .perArchive: return "目标/A.zip/…、目标/B.zip/…，互不干扰"
        case .flat: return "都放在同一层，重复的自动加「 2」「 3」"
        case .original: return "按包里的路径还原，可能和已有文件重名"
        }
    }
}

enum ArchiveStash {
    /// 「a、b、c 等 N 项」——错误框和浮条共用
    nonisolated static func previewList(_ names: [String], limit: Int = 3) -> String {
        let head = names.prefix(limit).joined(separator: "、")
        return names.count > limit ? "\(head) 等 \(names.count) 项" : head
    }

    /// 把临时解出来的文件放进目标位置。目标已存在时不覆盖，返回 false。
    ///
    /// 用 move 而不是「先查再改名」：move 遇到同名目标自己就失败，
    /// 查完到落位之间被别人建了文件也不会盖掉——这正是「预检查之后才出现」
    /// 那条竞态的兜底，也是能稳定测到的那条路径。
    nonisolated static func installExport(_ produced: URL, to target: URL) throws -> Bool {
        let fm = FileManager.default
        do {
            try fm.moveItem(at: produced, to: target)
            return true
        } catch {
            if fm.fileExists(atPath: target.path) { return false }
            throw error
        }
    }

    /// 单个暂存项的落盘：按布局决定落点。
    /// 先解到目标同卷的隐藏目录，再 move 过去——同卷是改名，不额外拷一份；
    /// 取消或失败时目标目录里一个字节都不会出现，只留下待删的临时目录。
    nonisolated static func exportStashItem(_ item: StashItem, to destination: URL,
                                           layout: StashLayout, password: String?,
                                           jobID: UUID? = nil) throws -> StashExport {
        let fm = FileManager.default

        let target: URL
        switch layout {
        case .perArchive:
            target = destination
                .appendingPathComponent(item.archive.deletingPathExtension().lastPathComponent,
                                        isDirectory: true)
                .appendingPathComponent(item.path)
        case .original:
            target = destination.appendingPathComponent(item.path)
        case .flat:
            target = UniquePath.file(destination.appendingPathComponent(
                (item.path as NSString).lastPathComponent))
        }

        // 早跳过：已经存在就别为必被丢弃的文件白解一遍
        if fm.fileExists(atPath: target.path) { return StashExport(url: target, skipped: true) }

        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".rrzip-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try ArchiveService.extract(item.archive, entries: [item.path], to: staging,
                                   password: password, jobID: jobID)
        let produced = staging.appendingPathComponent(item.path)
        // 引擎返回 0 但文件不在（条目名对不上时会这样），不能算导出成功
        guard fm.fileExists(atPath: produced.path) else {
            throw ArchiveError.tool("「\(item.name)」没有解出来")
        }
        guard try installExport(produced, to: target) else {
            return StashExport(url: target, skipped: true)
        }
        return StashExport(url: target, skipped: false)
    }

}

extension ArchiveModel {
    // MARK: - 暂存区

    /// 把当前选中项放进暂存区
    func addSelectionToStash() {
        guard let frame = current else { return }
        let items = selectionOrder.filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        for entry in items where !entry.isDirectory {
            let item = StashItem(archive: frame.archive, path: entry.path, size: entry.size)
            if !stash.contains(where: { $0.archive == item.archive && $0.path == item.path }) {
                updateStash { $0.append(item) }
            }
        }
        isStashVisible = true
        status = "已加入暂存 · 共 \(stash.count) 项"
        selection = []
    }

    /// 拖拽加入：按包内路径登记，不需要先把文件解出来
    func addToStash(archive: URL, path: String, size: Int64) {
        guard !path.hasSuffix("/") else { return }
        if !stash.contains(where: { $0.archive == archive && $0.path == path }) {
            updateStash { $0.append(StashItem(archive: archive, path: path, size: size)) }
        }
        isStashVisible = true
        status = "已加入暂存 · 共 \(stash.count) 项"
    }

    func removeFromStash(_ item: StashItem) {
        updateStash { $0.removeAll { $0.id == item.id } }
    }

    func clearStash() {
        updateStash { $0.removeAll() }
        isStashVisible = false
    }

    /// 把暂存项全部解压到用户选的目录。按 stashLayout 分目录，绝不覆盖已有文件
    func exportStash() {
        guard !stash.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.message = "把暂存的 \(stash.count) 个文件导出到"
        panel.prompt = "导出"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportStash(to: destination)
    }

    /// 落点已定时的导出入口：面板走上面那个，测试直接调这个。
    /// 和压缩、暂存打包共用同一条队列，取消只停自己。
    func exportStash(to destination: URL) {
        guard !stash.isEmpty else { return }
        let items = stash
        let passwordMap = passwords
        let layout = stashLayout
        submitJob(title: "正在导出暂存", detail: "\(items.count) 项") { [weak self] jobID in
            guard let self else { return .cancelled }
            return await self.runStashExportJob(to: destination, items: items,
                                                passwords: passwordMap,
                                                layout: layout, jobID: jobID)
        }
    }

    private func runStashExportJob(to destination: URL, items: [StashItem],
                                   passwords passwordMap: [String: String],
                                   layout: StashLayout, jobID: UUID) async -> JobResult {
        var exported = 0
        /// 目标已存在、按「不覆盖」跳过的
        var skipped: [String] = []
        /// 真的失败了的，连原因一起记
        var failed: [String] = []

        do {
            for (index, item) in items.enumerated() {
                if TaskRegistry.wasCancelled(jobID) { throw ArchiveError.cancelled }
                status = "正在导出 \(index + 1)/\(items.count)…"
                do {
                    let outcome = try await Task.detached(priority: .userInitiated) {
                        try Self.exportStashItem(item, to: destination, layout: layout,
                                                 password: passwordMap[item.archive.path],
                                                 jobID: jobID)
                    }.value
                    if outcome.skipped { skipped.append(item.name) } else { exported += 1 }
                } catch ArchiveError.cancelled {
                    throw ArchiveError.cancelled
                } catch {
                    failed.append("\(item.name)：\(error.localizedDescription)")
                }
            }
        } catch ArchiveError.cancelled {
            // 和导出到一半的目录一样，这里只能如实说，不假装干净
            status = "已取消，目标目录可能留有部分已导出文件"
            return .cancelled
        } catch {
            status = "导出失败"
            return .failed(error.localizedDescription)
        }

        if !skipped.isEmpty {
            // 状态栏放不下长长的名单，浮条里说清楚哪些没导
            notice = "未覆盖已存在的文件：" + Self.previewList(skipped)
        }
        if !failed.isEmpty {
            status = exported > 0 ? "已导出 \(exported) 项 · \(failed.count) 项失败"
                                  : "导出失败"
            return .failed("这些没导出来：\n" + Self.previewList(failed, limit: 5))
        }

        status = skipped.isEmpty ? "已导出 \(exported) 项"
                                 : "已导出 \(exported) 项 · \(skipped.count) 项已存在，未覆盖"
        // 有跳过就留着暂存项：用户可能想换个目录再导一次
        if skipped.isEmpty { clearStash() }
        return .succeeded
    }

    nonisolated static func previewList(_ names: [String], limit: Int = 3) -> String {
        ArchiveStash.previewList(names, limit: limit)
    }

    nonisolated static func installExport(_ produced: URL, to target: URL) throws -> Bool {
        try ArchiveStash.installExport(produced, to: target)
    }

    nonisolated static func exportStashItem(_ item: StashItem, to destination: URL,
                                            layout: StashLayout, password: String?,
                                            jobID: UUID? = nil) throws -> StashExport {
        try ArchiveStash.exportStashItem(item, to: destination, layout: layout,
                                         password: password, jobID: jobID)
    }

    /// 把暂存项打包成一个新的 zip
    func compressStash() {
        guard !stash.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "暂存.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let output = panel.url else { return }
        packStash(to: output)
    }

    /// 落点已定时的打包入口：面板走上面那个，测试直接调这个。
    ///
    /// 「解出暂存项 → 压成一个 ZIP」整段都在队列里，而不是只有最后一步：
    /// 以前它自己起一个 Task，压大目录时点打包会真的并行跑两个进程，
    /// 取消也管不着它。
    func packStash(to output: URL) {
        guard !stash.isEmpty else { return }
        let items = stash
        let passwordMap = passwords
        submitJob(title: "正在打包暂存", detail: output.lastPathComponent) { [weak self] jobID in
            guard let self else { return .cancelled }
            return await self.runStashPackJob(output: output, items: items,
                                              passwords: passwordMap, jobID: jobID)
        }
    }

    /// 暂存打包的执行体。每一步都可能失败，失败了就停：
    /// 以前解压用 `try?` 吞掉错误，照样把「预期路径」塞进打包清单，
    /// 最后得到一个缺文件的包，用户还以为是成功的。
    private func runStashPackJob(output: URL, items: [StashItem],
                                 passwords passwordMap: [String: String],
                                 jobID: UUID) async -> JobResult {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-stash-\(UUID().uuidString)", isDirectory: true)
        // 成功、失败、取消都从这里收尾：临时解出来的东西一个不留
        defer { try? FileManager.default.removeItem(at: staging) }

        func checkCancelled() throws {
            if TaskRegistry.wasCancelled(jobID) { throw ArchiveError.cancelled }
        }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            var files: [URL] = []
            for (index, item) in items.enumerated() {
                try checkCancelled()
                status = "正在解压暂存项 \(index + 1)/\(items.count)…"

                let folder = staging.appendingPathComponent(
                    item.archive.deletingPathExtension().lastPathComponent, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ArchiveService.extract(item.archive, entries: [item.path],
                                                   to: folder,
                                                   password: passwordMap[item.archive.path],
                                                   jobID: jobID)
                    }.value
                } catch ArchiveError.cancelled {
                    throw ArchiveError.cancelled
                } catch {
                    // 是哪个文件、为什么，一样都不能省：打包结果得对得上用户的预期
                    throw ArchiveError.tool("「\(item.name)」解压失败：\(error.localizedDescription)")
                }

                var file = folder.appendingPathComponent(item.path)
                // 引擎没报错但文件不在，同样算失败——继续压只会漏文件
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw ArchiveError.tool("「\(item.name)」没有解出来，已停止打包")
                }
                // 同名时加包名前缀：7-Zip 不接受两个不同目录下的同名文件
                let ext = file.pathExtension
                let base = file.deletingPathExtension().lastPathComponent
                let renamed = folder
                    .appendingPathComponent("\(base)-\(item.archive.deletingPathExtension().lastPathComponent)")
                    .appendingPathExtension(ext)
                if (try? FileManager.default.moveItem(at: file, to: renamed)) != nil {
                    file = renamed
                }
                files.append(file)
            }

            // 解压阶段耗掉的时间里用户可能已经点了取消，别再往下压了
            try checkCancelled()
            status = "正在打包 \(files.count) 项…"
            let filesToArchive = files
            let onProgress: @Sendable (Double) -> Void = { [weak self] value in
                self?.reportProgress(value, for: jobID)
            }
            try await Task.detached(priority: .userInitiated) {
                try Self.writeArchive(at: output, from: filesToArchive,
                                      format: .zip, password: "", volume: nil,
                                      level: CompressLevel.normal.argument,
                                      jobID: jobID, onProgress: onProgress)
            }.value

            status = "已打包 \(files.count) 项 · \(output.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([output])
            return .succeeded
        } catch ArchiveError.cancelled {
            status = "已取消"
            return .cancelled
        } catch {
            status = "打包失败"
            errorMessage = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

}
