// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  主程序里的访达归档执行、日志与通知。
//
import AppKit
import Darwin
import Foundation
// 同上：UNUserNotificationCenter 未标 Sendable，@preconcurrency 只压警告不改语义
@preconcurrency import UserNotifications

// MARK: - 任务日志

struct JobRecord: Codable, Sendable {
    struct Payload: Codable, Sendable {
        var succeeded: [String]
        var failed: [String]
        var needsPassword: [String]
        var skippedFiles: Int
        var destination: String?
    }

    let id: String
    let op: String
    let startedAt: Date
    let finishedAt: Date
    let payload: Payload
}

/// JSONL，一条一行，保留最近 200 条。
/// 通知被系统关掉时，这里至少还能看到「刚才那两个包解到哪了」。
enum FinderJobLog {
    private static let ioQueue = DispatchQueue(label: "com.rrzip.finder.joblog")

    static var fileURL: URL {
        SharedPaths.support.appendingPathComponent("finder-jobs.log")
    }

    static func append(_ record: JobRecord, limit: Int = 200) {
        ioQueue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let line = try? encoder.encode(record) else { return }

            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            var data = (try? Data(contentsOf: url)) ?? Data()
            data.append(line)
            data.append(0x0A)

            // 超上限就只留最后 limit 条，避免日志无限长
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            if lines.count > limit {
                data = Data(lines.suffix(limit).flatMap { Array($0) + [0x0A] })
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 新的在前
    static func recent(_ limit: Int = 20) -> [JobRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .suffix(limit)
            .compactMap { try? decoder.decode(JobRecord.self, from: Data($0)) }
        return Array(records.reversed())
    }
}

// MARK: - 通知

enum FinderNotifier {

    /// 扩展不能自己申请授权，只能投递。主程序启动时申请一次。
    ///
    /// 关键：**通知不等于反馈的全部**。用户拒绝过通知、或系统压掉横幅时，
    /// 任务做完了却「什么都没发生」——这是最伤人的状态。
    /// 所以先按 reveal 把产物在访达里亮出来，通知只当补充。
    /// 注意「解压到此处」不该 reveal：产物就是当前目录，跳过去没有意义，
    /// 这种情况只能靠通知，调用方传 `reveal: nil`。
    static func report(_ outcome: JobOutcome, verb: String, reveal: URL?) {
        revealInFinder(reveal)

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard allowed else { return }

            let content = UNMutableNotificationContent()
            content.title = FinderNoticeText.title(for: outcome, verb: verb)
            if let body = FinderNoticeText.body(for: outcome) {
                content.body = body
            }
            if let reveal {
                content.userInfo = ["reveal": reveal.path]
            }

            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                               content: content,
                                               trigger: nil)
            center.add(request) { _ in }
        }
    }

    /// 同一批多选会调多次，1 秒内只跳一次，别把访达刷屏（仅在主线程访问，消除跨线程竞态）
    @MainActor private static var lastReveal = Date.distantPast

    /// 在访达里选中已发布的产物。
    private static func revealInFinder(_ url: URL?) {
        guard let url else { return }
        Task { @MainActor in
            let now = Date()
            guard now.timeIntervalSince(lastReveal) > 1.0 else { return }
            lastReveal = now
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// MARK: - 执行

enum FinderJobRunner {

    /// 解压。加密包在解压前就能判出来，不必等 7zz 报错再退。
    static func extract(_ archives: [URL], mode: FinderSettings.ExtractStrategy) -> JobOutcome {
        var outcome = JobOutcome()

        for plan in FinderJobPlanner.planExtraction(of: archives, mode: mode) {
            let name = plan.archive.lastPathComponent
            do {
                outcome.skippedFiles += try extract(plan, password: nil)
                outcome.succeeded.append(name)
                outcome.destination = plan.destination
                if mode == .newFolder { outcome.outputs.append(plan.destination) }
            } catch ArchiveError.needsPassword {
                outcome.needsPassword.append(name)
            } catch {
                outcome.failed.append(.init(name: name, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    static func extract(_ plan: PlannedExtraction, password: String?) throws -> Int {
        let existed = FileManager.default.fileExists(atPath: plan.destination.path)
        let entries = try ArchiveService.list(plan.archive, password: password)
        let clashes = (existed && plan.onConflict == .skip)
            ? conflictCount(entries: entries, destination: plan.destination) : 0
        do {
            try ArchiveService.extract(plan.archive, entries: [], to: plan.destination,
                                       password: password, onConflict: plan.onConflict)
            return clashes
        } catch {
            removeIfNewlyCreated(plan.destination, existedBefore: existed)
            throw error
        }
    }

    /// 先在同卷临时目录解压，完成前不写入目标。取消时只删除本次的暂存区。
    static func extract(_ plan: PlannedExtraction, password: String?, intoNewFolder: Bool,
                        jobID: UUID?, onProgress: (@Sendable (Double) -> Void)?,
                        entries: [String] = [], createDestination: Bool = false) throws
        -> (destination: URL, skipped: Int) {
        try TaskRegistry.checkCancellation(jobID)
        let fm = FileManager.default
        let destination = plan.destination
        let missing = !intoNewFolder && createDestination && !fm.fileExists(atPath: destination.path)
        var directory: Int32 = -1
        defer { if directory >= 0 { close(directory) } }
        if !intoNewFolder, !missing { directory = try openDestination(destination) }
        var parent = intoNewFolder ? destination.deletingLastPathComponent() : destination
        if missing {
            while !fm.fileExists(atPath: parent.path), parent.path != "/" {
                parent.deleteLastPathComponent()
            }
        }
        let staged = parent.appendingPathComponent(".rrzip-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staged.path, intoNewFolder ? 0o777 : 0o700) == 0 else { throw fileError(errno) }
        defer { removeExtractionStage(staged) }
        try ArchiveService.extract(plan.archive, entries: entries, to: staged, password: password,
                                   onConflict: .overwrite, jobID: jobID, onProgress: onProgress,
                                   validateSelection: true)
        try TaskRegistry.checkCancellation(jobID)

        if intoNewFolder {
            return (try publish(staged, as: destination, directory: true), 0)
        }
        if missing {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            directory = try openDestination(destination)
        }
        return (destination, try publishContents(of: staged, into: directory, jobID: jobID,
                                                onConflict: plan.onConflict))
    }

    private static func openDestination(_ url: URL) throws -> Int32 {
        let directory = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw fileError(errno) }
        return directory
    }

    /// 压缩。`each` 为真时每个项目各生成一个包。
    static func compress(_ urls: [URL], format: CompressionFormat, each: Bool) -> JobOutcome {
        // 无任务 ID 的调用没有取消信号。
        (try? compress(urls, format: format, each: each, jobID: nil, onProgress: nil)) ?? JobOutcome()
    }

    static func compress(_ urls: [URL], format: CompressionFormat, each: Bool, jobID: UUID?,
                         onProgress: (@Sendable (Double) -> Void)?) throws -> JobOutcome {
        var outcome = JobOutcome()
        guard let first = urls.first else { return outcome }

        if each {
            for url in urls {
                let hint = url.deletingPathExtension().lastPathComponent
                append(try compressGroup([url], format: format, nameHint: hint,
                                         jobID: jobID, onProgress: onProgress), to: &outcome)
            }
        } else {
            let hint: String
            if urls.count == 1 {
                hint = first.deletingPathExtension().lastPathComponent
            } else {
                hint = first.deletingLastPathComponent().lastPathComponent
            }
            append(try compressGroup(urls, format: format, nameHint: hint,
                                     jobID: jobID, onProgress: onProgress), to: &outcome)
        }
        return outcome
    }

    enum CompressionFormat: String, Sendable {
        case zip
        case sevenZip = "7z"

        var label: String { self == .zip ? "ZIP" : "7Z" }
    }

    // MARK: 内部

    private static func compressGroup(_ urls: [URL], format: CompressionFormat,
                                      nameHint: String, jobID: UUID?,
                                      onProgress: (@Sendable (Double) -> Void)?) throws -> JobOutcome {
        try TaskRegistry.checkCancellation(jobID)
        var outcome = JobOutcome()
        guard let first = urls.first else { return outcome }

        let folder = first.deletingLastPathComponent()
        let base = nameHint.isEmpty ? "归档" : nameHint
        let requested = folder.appendingPathComponent(base).appendingPathExtension(format.rawValue)
        let staged = folder.appendingPathComponent(".rrzip-\(UUID().uuidString)")
            .appendingPathExtension(format.rawValue)
        defer { try? FileManager.default.removeItem(at: staged) }

        do {
            try ArchiveWriter.writeArchive(at: staged, from: urls,
                                           format: format == .zip ? .zip : .sevenZip,
                                           password: "", volume: nil, jobID: jobID, onProgress: onProgress)
            try TaskRegistry.checkCancellation(jobID)
            let output = try publish(staged, as: requested)
            outcome.succeeded = urls.count == 1 ? [first.lastPathComponent] : [output.lastPathComponent]
            outcome.destination = folder
            outcome.outputs = [output]
        } catch ArchiveError.cancelled {
            throw ArchiveError.cancelled
        } catch {
            outcome.failed.append(.init(name: requested.lastPathComponent,
                                        reason: error.localizedDescription))
        }
        return outcome
    }

    static func append(_ part: JobOutcome, to outcome: inout JobOutcome) {
        outcome.succeeded += part.succeeded
        outcome.failed += part.failed
        outcome.needsPassword += part.needsPassword
        outcome.skippedFiles += part.skippedFiles
        outcome.outputs += part.outputs
        if outcome.destination == nil { outcome.destination = part.destination }
    }

    /// 与临时文件同目录，原子发布；并行任务抢先占名时再选一次。
    static func publish(_ staged: URL, as requested: URL, directory: Bool = false) throws -> URL {
        for _ in 0..<10 {
            let output = directory ? UniquePath.directory(requested) : UniquePath.file(requested)
            if renamex_np(staged.path, output.path, UInt32(RENAME_EXCL)) == 0 { return output }
            let code = errno
            guard code == EEXIST else {
                throw fileError(code)
            }
        }
        throw ArchiveError.tool("无法选定未占用的归档产物名称")
    }

    private static func fileError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// 只改即将丢弃的真实暂存目录。整个搬出的目录仍保留归档中的权限。
    private static func makeStageWritable(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw fileError(errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        if (info.st_mode & 0o700) != 0o700,
           fchmodat(AT_FDCWD, url.path, (info.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW) != 0 {
            throw fileError(errno)
        }
        return true
    }

    private static func removeExtractionStage(_ url: URL) {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: url)
        } catch {
            guard (try? makeStageWritable(url)) == true else { return }
            if let descendants = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let child as URL in descendants { _ = try? makeStageWritable(child) }
            }
            try? fm.removeItem(at: url)
        }
    }

    private static func publishChild(_ child: URL, into destination: Int32) throws -> Bool {
        let name = child.lastPathComponent
        let flags = UInt32(RENAME_EXCL)
        if renameatx_np(AT_FDCWD, child.path, destination, name, flags) == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        guard code == EACCES else { throw fileError(code) }

        // 跨父目录移动只读子目录时，macOS 也需要能更新该目录的「..」。
        var info = stat()
        guard lstat(child.path, &info) == 0 else { throw fileError(errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o700) != 0o700 else {
            throw fileError(code)
        }
        guard try makeStageWritable(child) else { throw ArchiveError.unsafePath(child.path) }
        let fd = open(child.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw fileError(errno) }
        defer { close(fd) }
        if renameatx_np(AT_FDCWD, child.path, destination, name, flags) == 0 {
            guard fchmod(fd, info.st_mode & 0o7777) == 0 else { throw fileError(errno) }
            return true
        }
        let retryCode = errno
        if retryCode == EEXIST { return false }
        throw fileError(retryCode)
    }

    /// 只合并真实目录。用已打开的目录描述符发布，避免既有软链或重名改变写入位置。
    private static func publishContents(of staged: URL, into destination: Int32?, jobID: UUID?,
                                        onConflict: ArchiveConflictPolicy) throws -> Int {
        try TaskRegistry.checkCancellation(jobID)
        guard try makeStageWritable(staged) else { throw ArchiveError.unsafePath(staged.path) }
        var skipped = 0
        for child in try FileManager.default.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil) {
            // 已发布的是完整文件或目录。取消只停止下一次发布，避免改动用户已经能看到的产物。
            try TaskRegistry.checkCancellation(jobID)
            let name = child.lastPathComponent
            if let destination, try publishChild(child, into: destination) { continue }
            var info = stat()
            guard lstat(child.path, &info) == 0 else { throw fileError(errno) }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                let next = destination.map { openat($0, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
                defer { if next >= 0 { close(next) } }
                if destination != nil, next < 0, errno != ENOTDIR, errno != ELOOP, errno != ENOENT {
                    throw fileError(errno)
                }
                skipped += try publishContents(of: child, into: next >= 0 ? next : nil, jobID: jobID,
                                               onConflict: onConflict)
            } else if let destination, onConflict == .overwrite {
                // renameat 替换同名文件或软链本身，绝不进入软链或删目录。
                guard renameat(AT_FDCWD, child.path, destination, name) == 0 else { throw fileError(errno) }
            } else {
                skipped += 1
            }
        }
        return skipped
    }

    /// 目标目录里已存在多少个包内同名文件（只数文件，不数目录，且过滤越界路径）
    private static func conflictCount(entries: [ArchiveEntry]?, destination: URL) -> Int {
        guard let entries else { return 0 }
        return entries.filter { entry in
            guard !entry.isDirectory else { return false }
            guard (try? ArchivePathGuard.validateRelative(entry.path)) != nil else { return false }
            let target = destination.appendingPathComponent(entry.path)
            guard (try? ArchivePathGuard.validateContained(target, within: destination)) != nil else { return false }
            return FileManager.default.fileExists(atPath: target.path)
        }.count
    }

    /// 失败时别留空目录：本次新建的删掉，本来就存在的别碰
    private static func removeIfNewlyCreated(_ url: URL, existedBefore: Bool) {
        guard !existedBefore else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: url.path),
              contents.isEmpty else { return }
        try? fm.removeItem(at: url)
    }
}
