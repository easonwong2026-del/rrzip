// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Foundation

enum CreateFormat: String, CaseIterable, Identifiable {
    case zip, sevenZip, tar, tgz
    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7Z（压缩率更高）"
        case .tar: return "TAR（不压缩）"
        case .tgz: return "TAR.GZ"
        }
    }

    var ext: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tgz: return "tgz"
        }
    }

    var usesSevenZip: Bool { self == .sevenZip }
}

/// 压缩级别。7zz 的 -mx 取值，数字越大越慢越小
enum CompressLevel: String, CaseIterable, Identifiable {
    case store, fast, normal, max
    var id: String { rawValue }

    var title: String {
        switch self {
        case .store: return "存储（不压缩）"
        case .fast: return "快速"
        case .normal: return "标准（推荐）"
        case .max: return "极限"
        }
    }

    var argument: Int {
        switch self {
        case .store: return 0
        case .fast: return 1
        case .normal: return 5
        case .max: return 9
        }
    }
}

enum CreateVolume: String, CaseIterable, Identifiable {
    case none, m100, m700, g1, g4
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不分卷"
        case .m100: return "每卷 100 MB"
        case .m700: return "每卷 700 MB"
        case .g1: return "每卷 1 GB"
        case .g4: return "每卷 4 GB"
        }
    }

    var argument: String? {
        switch self {
        case .none: return nil
        case .m100: return "100m"
        case .m700: return "700m"
        case .g1: return "1g"
        case .g4: return "4g"
        }
    }
}

/// 选完文件、等 sheet 确认参数的那一批
struct PendingCreate: Identifiable {
    let id = UUID()
    let items: [URL]
}

struct CreateOptions {
    var format: CreateFormat = .zip
    var password: String = ""
    var volume: CreateVolume = .none
    var level: CompressLevel = .normal
}

enum ArchiveWriter {
    // MARK: - 创建

    /// 原子写入：先在同目录写隐藏临时文件，成功后再替换目标。
    /// 覆盖同名包时不会先删旧文件，失败也能保留原来的包。
    nonisolated static func writeArchive(
        at output: URL,
        from items: [URL],
        format: CreateFormat,
        password: String,
        volume: String?,
        level: Int = 5,
        jobID: UUID? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let folder = output.deletingLastPathComponent()
        let base = output.deletingPathExtension().lastPathComponent
        let staged = folder
            .appendingPathComponent(".\(base)-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(output.pathExtension)

        func cleanupStaged() {
            try? fm.removeItem(at: staged)
            if let siblings = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for sibling in siblings where sibling.lastPathComponent.hasPrefix(staged.lastPathComponent + ".") {
                    try? fm.removeItem(at: sibling)
                }
            }
        }

        // 「必须 7zz」和「优先 7zz」要分开：
        // 7z / 加密 / 分卷 没有 7zz 就做不了，必须报错；
        // ZIP 只是想要 -mx —— bsdtar 的 zip 写入只 store，四档级别等于摆设
        // （选「极限」和「存储」压出来一样大），所以 ZIP 也走 7zz，
        // 但没 7zz 时还能退回 ditto，不该直接失败。
        let requiresSevenZip = format.usesSevenZip || !password.isEmpty || volume != nil
        let prefersSevenZip = format == .zip && SevenZip.isAvailable

        do {
            if requiresSevenZip {
                guard SevenZip.isAvailable else { throw ArchiveError.engineUnavailable }
                try SevenZip.create(
                    at: staged, from: items,
                    format: format == .sevenZip ? "7z" : format.ext,
                    password: password.isEmpty ? nil : password,
                    volume: volume,
                    level: level,
                    jobID: jobID,
                    onProgress: onProgress
                )
            } else if prefersSevenZip {
                try SevenZip.create(
                    at: staged, from: items,
                    format: format.ext,
                    password: nil,
                    volume: nil,
                    level: level,
                    jobID: jobID,
                    onProgress: onProgress
                )
            } else if format == .zip {
                // 没有 7zz 时：单源还能用 ditto 撑住（deflate，但选不了级别）；
                // 多源只剩 bsdtar 的 store，四档级别彻底失效。
                // 与其静默给一个「压了等于没压」的包，不如明说引擎缺失。
                guard items.count == 1 else { throw ArchiveError.engineUnavailable }
                try Tar.createZip(at: staged, from: items[0], jobID: jobID)
            } else {
                // TAR / TGZ 走 bsdtar。它也支持取消：
                // 不传 jobID 的话，这两个格式的任务按「取消」不会有任何反应。
                try Tar.create(at: staged, from: items, format: format.ext, jobID: jobID)
            }
            // 压完了但取消信号刚好赶到：这时候交出产物等于没取消。
            // 拿掉这一行，用户点了取消却仍然得到一个包（旧的同名包还会被替换）。
            if let jobID, TaskRegistry.wasCancelled(jobID) { throw ArchiveError.cancelled }
            // 从这里开始是不可中断的收尾：要么整组换上去，要么按
            // commitStaged 里的备份 / 回滚收场。分卷是多文件，中途被打断
            // 就会两头空，所以这一段刻意不再看取消信号。
            try commitStaged(staged, to: output, hasVolumes: volume != nil)
        } catch {
            cleanupStaged()
            throw error
        }
    }

    /// 把临时产物换成目标名。有分卷时按前缀整组替换。
    nonisolated static func commitStaged(_ staged: URL, to output: URL, hasVolumes: Bool) throws {
        let fm = FileManager.default
        let folder = output.deletingLastPathComponent()

        if hasVolumes {
            // 旧分卷先改名成备份，不能直接删。
            // 分卷是多文件，没有原子替换可用：以前是「先删旧的、再移新的」，
            // 移到一半失败（磁盘满、进程被杀、权限变了）就两头空——
            // 用户原来的包没了，新的也不完整。
            let oldVolumes = volumeFiles(of: output)
            let token = String(UUID().uuidString.prefix(8))
            var backups: [(original: URL, backup: URL)] = []

            for old in oldVolumes {
                let backup = folder.appendingPathComponent(
                    old.lastPathComponent + ".rrzip-old-" + token)
                do {
                    try fm.moveItem(at: old, to: backup)
                    backups.append((old, backup))
                } catch {
                    // 备份都做不成，把已经改名的还回去，原样退出
                    for (original, backup) in backups {
                        try? fm.moveItem(at: backup, to: original)
                    }
                    throw error
                }
            }

            do {
                try moveVolumeFiles(from: staged, to: output)
            } catch {
                // 回滚：清掉刚移进去的新分卷，再把旧分卷改回来
                for new in volumeFiles(of: output) { try? fm.removeItem(at: new) }
                for (original, backup) in backups {
                    try? fm.moveItem(at: backup, to: original)
                }
                throw error
            }

            for (_, backup) in backups { try? fm.removeItem(at: backup) }
        } else if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: output)
        }
    }

    /// 旧分卷：只认 `foo.zip.001` 这种纯数字后缀。
    /// 以前用 `hasPrefix(outName + ".")`，`foo.zip.bak`、`foo.zip.old` 都会被当成分卷删掉。
    nonisolated static func volumeFiles(of output: URL) -> [URL] {
        let fm = FileManager.default
        let folder = output.deletingLastPathComponent()
        let outName = output.lastPathComponent
        guard let siblings = try? fm.contentsOfDirectory(at: folder,
                                                        includingPropertiesForKeys: nil) else {
            return []
        }
        return siblings.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(outName + ".") else { return false }
            let rest = name.dropFirst(outName.count + 1)
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 把 `staged.001 / staged.002…` 依次改名成 `output.001 / output.002…`
    nonisolated static func moveVolumeFiles(from staged: URL, to output: URL) throws {
        let fm = FileManager.default
        let folder = output.deletingLastPathComponent()
        let stagedName = staged.lastPathComponent
        let outName = output.lastPathComponent

        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(stagedName + ".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            // 一个分卷都没生成，说明 7zz 那边出了问题；别把旧的删了当成功
            throw ArchiveError.tool("分卷产物缺失：\(stagedName).001")
        }

        for file in files {
            let suffix = file.lastPathComponent.dropFirst(stagedName.count)
            try fm.moveItem(at: file,
                            to: folder.appendingPathComponent(outName + suffix))
        }
    }

}

extension ArchiveModel {
    nonisolated static func writeArchive(
        at output: URL, from items: [URL], format: CreateFormat,
        password: String, volume: String?, level: Int = 5, jobID: UUID? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        try ArchiveWriter.writeArchive(at: output, from: items, format: format, password: password,
                                       volume: volume, level: level, jobID: jobID, onProgress: onProgress)
    }

    nonisolated static func commitStaged(_ staged: URL, to output: URL, hasVolumes: Bool) throws {
        try ArchiveWriter.commitStaged(staged, to: output, hasVolumes: hasVolumes)
    }

    nonisolated static func volumeFiles(of output: URL) -> [URL] {
        ArchiveWriter.volumeFiles(of: output)
    }

    nonisolated static func moveVolumeFiles(from staged: URL, to output: URL) throws {
        try ArchiveWriter.moveVolumeFiles(from: staged, to: output)
    }

    // MARK: - 快速压缩（首页）

    /// 首页拖入：不弹选项，直接在同目录生成 ZIP。重名自动加序号。
    ///
    /// 走的是和「新建压缩包」同一条队列：前台正在解压时不会插队并行，
    /// 取消也只停自己这一条。`completion` 在任务真正有结局后才回调——
    /// 以前是发起压缩后立刻写「已生成 ZIP」，包还没影子就先报成功了。
    func quickCompress(_ urls: [URL], completion: (@MainActor (JobResult, URL) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        let folder = urls[0].deletingLastPathComponent()
        let base: String
        if urls.count == 1 {
            let name = urls[0].deletingPathExtension().lastPathComponent
            base = name.isEmpty ? "归档" : name
        } else {
            let name = folder.lastPathComponent
            base = name.isEmpty ? "归档" : name
        }
        // 落点等任务真正开始跑时再算：排队期间前一个同名任务可能已经把
        // 「A.zip」占了，提交时就算好会让第二个任务覆盖掉第一个的产物。
        let target = folder.appendingPathComponent(base).appendingPathExtension("zip")

        submitJob(title: "正在压缩", detail: target.lastPathComponent) { [weak self] jobID in
            guard let self else { return .cancelled }
            let output = Self.uniqueOutput(target)
            let result = await self.runArchiveJob(
                output: output, items: urls, format: .zip,
                password: "", volume: nil, level: CompressLevel.normal.argument,
                runningText: "正在压缩 \(urls.count) 项…", doneVerb: "已生成",
                jobID: jobID
            )
            completion?(result, output)
            return result
        }
    }

    /// 压缩任务的公共执行体：状态、写盘、完成后在访达里选中产物、取消与失败的落账。
    /// 新建面板和首页快速压缩只差几句文案，其余不该各写一遍——
    /// 上一次写两遍的结果就是一边漏传 jobID，取消按下去没反应。
    private func runArchiveJob(
        output: URL, items: [URL], format: CreateFormat,
        password: String, volume: String?, level: Int,
        runningText: String, doneVerb: String,
        jobID: UUID
    ) async -> JobResult {
        // 状态在真正开始执行时才写。入队时就写，会让状态栏提前显示
        // 「正在压缩」，而实际还在等前一个任务。
        status = runningText
        do {
            let onProgress: @Sendable (Double) -> Void = { [weak self] value in
                self?.reportProgress(value, for: jobID)
            }
            try await Task.detached {
                // 先写临时文件，成功后才替换同名旧包：失败时原文件不动
                try Self.writeArchive(
                    at: output, from: items, format: format,
                    password: password, volume: volume,
                    level: level, jobID: jobID, onProgress: onProgress
                )
            }.value
            if volume != nil {
                let parts = ArchiveModel.volumeFiles(of: output)
                status = "\(doneVerb) \(output.lastPathComponent).001（分 \(parts.count) 卷）"
                NSWorkspace.shared.activateFileViewerSelecting(Array(parts.prefix(1)))
            } else {
                status = "\(doneVerb) \(output.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
            return .succeeded
        } catch ArchiveError.cancelled {
            status = "已取消"
            // 临时产物由 writeArchive 自己清（staged 与它的分卷）。
            // 这里千万不能碰 output：用户可能选了一个已存在的同名包，
            // 在「取消」这个动作上删掉它，等于把旧文件毁了。
            return .cancelled
        } catch {
            errorMessage = error.localizedDescription
            status = "压缩失败"
            return .failed(error.localizedDescription)
        }
    }

    /// 目标已存在时找下一个可用名字，绝不覆盖（实现见 UniquePath）
    nonisolated static func uniqueOutput(_ url: URL) -> URL { UniquePath.file(url) }

    /// 目录版：不拼扩展名
    nonisolated static func uniqueDirectory(_ url: URL) -> URL { UniquePath.directory(url) }

    func createArchive() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.message = "选择要打包的文件或文件夹"
        picker.prompt = "下一步"
        guard picker.runModal() == .OK, !picker.urls.isEmpty else { return }
        // 参数交给 SwiftUI sheet；确认后由 finishCreate 选落点并写盘
        pendingCreate = PendingCreate(items: picker.urls)
    }

    /// sheet 确认后：选保存位置并写盘（items 由调用方带过来，此时 sheet 已关）
    func finishCreate(_ options: CreateOptions, items: [URL]) {
        guard !items.isEmpty else { return }

        let save = NSSavePanel()
        save.message = "保存压缩包"
        save.nameFieldStringValue = defaultName(for: items, format: options.format)
        guard save.runModal() == .OK, let picked = save.url else { return }
        var target = picked
        if target.pathExtension.lowercased() != options.format.ext {
            target = target.deletingPathExtension().appendingPathExtension(options.format.ext)
        }
        let output = target

        // tar / tgz 不支持密码与分卷，选项里先关掉了，这里再兜一层
        let plain = options.format == .tar || options.format == .tgz
        let password = plain ? "" : options.password
        let volume = plain ? nil : options.volume.argument

        // 分卷包在保存面板里是「看不见」的：目录里只有 abc.zip.001，
        // 没有 abc.zip 这个实体，所以面板不会提示「已存在」。
        // 但提交时会把整组旧分卷换掉——补一次确认，别让它变成静默覆盖。
        if volume != nil {
            let existing = ArchiveModel.volumeFiles(of: output)
            if !existing.isEmpty {
                let alert = NSAlert()
                alert.messageText = "已存在同名的分卷压缩包"
                alert.informativeText = "\(output.lastPathComponent).001 等 \(existing.count) 个文件会被替换。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "替换")
                alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }

        submitJob(title: "正在压缩", detail: output.lastPathComponent) { [weak self] jobID in
            guard let self else { return .cancelled }
            return await self.runArchiveJob(
                output: output, items: items, format: options.format,
                password: password, volume: volume, level: options.level.argument,
                runningText: "正在压缩…", doneVerb: "已创建",
                jobID: jobID
            )
        }
    }

    private func defaultName(for items: [URL], format: CreateFormat) -> String {
        let base = items.count == 1
            ? items[0].deletingPathExtension().lastPathComponent
            : "归档"
        return "\(base).\(format.ext)"
    }

    // MARK: - 原地编辑

    /// 往当前归档里加文件（落在当前目录下）
    func addFiles() {
        guard let frame = current else { return }
        guard !frame.isNested else {
            errorMessage = "嵌套包里的内容来自外层包的临时副本，改动不会保存。\n请先把内层包导出，再单独打开编辑。"
            return
        }
        let panel = NSOpenPanel()
        panel.message = "选择要加入 \(frame.archive.lastPathComponent) 的文件"
        panel.prompt = "加入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let items = panel.urls
        let archive = frame.archive
        let prefix = frame.prefix

        // 同名文件会被 7-Zip 直接替换，先问一句
        let existing = Set(Self.children(of: prefix, in: frame.entries).map(\.name))
        let conflicts = items.filter { existing.contains($0.lastPathComponent) }
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = "有 \(conflicts.count) 个同名文件"
            alert.informativeText = "继续会覆盖压缩包里的同名文件：\n"
                + conflicts.prefix(5).map(\.lastPathComponent).joined(separator: "、")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "覆盖")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        performAdd(items, to: archive, prefix: prefix, password: passwords[archive.path])
    }

    /// 原地添加的执行体：面板与同名确认留在 `addFiles` 里，测试直接调这个。
    ///
    /// 登记（`FormalWriteLedger`）**同步**发生在派发任务之前：这一下之后按 ⌘Q，
    /// 退出协调就能看见「有东西正在改用户的原包」，从而只等不杀。
    @discardableResult
    func performAdd(_ items: [URL], to archive: URL, prefix: String,
                    password: String? = nil) -> Task<Void, Never> {
        guard let token = FormalWriteLedger.shared.begin(
            .inPlaceEdit,
            label: "向 \(archive.lastPathComponent) 添加 \(items.count) 项"
        ) else {
            // 退出流程已接管：新的正式写入一律不接，连 7zz 都不启动
            status = "正在退出，未执行新的写入"
            notice = "正在退出，不再接受新的写入操作"
            return Task {}
        }
        setArchiveEditing(true)
        status = "正在加入 \(items.count) 项…"

        return Task { @MainActor in
            defer {
                FormalWriteLedger.shared.end(token)
                self.notifyWorkDrainedIfNeeded()
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SevenZip.add(archive, items: items, prefix: prefix, password: password)
                }.value
                if self.current?.archive.path == archive.path {
                    self.loadFrame(url: archive, resetTrail: true, restorePrefix: prefix)
                } else {
                    self.setArchiveEditing(false)
                    self.status = "已加入 \(items.count) 项"
                }
            } catch {
                self.setArchiveEditing(false)
                self.status = "加入失败"
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 删除选中的条目
    func deleteSelection() {
        guard let frame = current else { return }
        guard !frame.isNested else {
            errorMessage = "嵌套包里的内容来自外层包的临时副本，改动不会保存。\n请先把内层包导出，再单独打开编辑。"
            return
        }
        let targets = selectionOrder.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "从压缩包中删除 \(targets.count) 项？"
        alert.informativeText = "只改动 \(frame.archive.lastPathComponent)，原始文件不受影响。删除后无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let paths = targets.map(\.path)
        let archive = frame.archive
        let prefix = frame.prefix
        performDelete(paths, from: archive, prefix: prefix, password: passwords[archive.path])
    }

    /// 原地删除的执行体：二次确认留在 `deleteSelection` 里，测试直接调这个。
    /// 与添加同源：登记成正式写入，退出时等它跑完，绝不 terminate 正在改包的 7zz。
    @discardableResult
    func performDelete(_ paths: [String], from archive: URL, prefix: String,
                       password: String? = nil) -> Task<Void, Never> {
        guard let token = FormalWriteLedger.shared.begin(
            .inPlaceEdit,
            label: "从 \(archive.lastPathComponent) 删除 \(paths.count) 项"
        ) else {
            status = "正在退出，未执行新的写入"
            notice = "正在退出，不再接受新的写入操作"
            return Task {}
        }
        setArchiveEditing(true)
        status = "正在删除 \(paths.count) 项…"

        return Task { @MainActor in
            defer {
                FormalWriteLedger.shared.end(token)
                self.notifyWorkDrainedIfNeeded()
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SevenZip.remove(archive, entries: paths, password: password)
                }.value
                if self.current?.archive.path == archive.path {
                    self.loadFrame(url: archive, resetTrail: true, restorePrefix: prefix)
                } else {
                    self.setArchiveEditing(false)
                    self.status = "已删除 \(paths.count) 项"
                }
            } catch {
                self.setArchiveEditing(false)
                self.status = "删除失败"
                self.errorMessage = error.localizedDescription
            }
        }
    }

}
