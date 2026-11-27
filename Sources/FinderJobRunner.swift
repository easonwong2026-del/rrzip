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

    /// 压缩。`each` 为真时每个项目各生成一个包。
    static func compress(_ urls: [URL], format: CompressionFormat, each: Bool) -> JobOutcome {
        var outcome = JobOutcome()
        guard let first = urls.first else { return outcome }

        if each {
            for url in urls {
                let hint = url.deletingPathExtension().lastPathComponent
                append(compressGroup([url], format: format, nameHint: hint), to: &outcome)
            }
        } else {
            let hint: String
            if urls.count == 1 {
                hint = first.deletingPathExtension().lastPathComponent
            } else {
                hint = first.deletingLastPathComponent().lastPathComponent
            }
            append(compressGroup(urls, format: format, nameHint: hint), to: &outcome)
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
                                      nameHint: String) -> JobOutcome {
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
                                           password: "", volume: nil)
            let output = try publish(staged, as: requested)
            outcome.succeeded = urls.count == 1 ? [first.lastPathComponent] : [output.lastPathComponent]
            outcome.destination = folder
            outcome.outputs = [output]
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
    static func publish(_ staged: URL, as requested: URL) throws -> URL {
        for _ in 0..<10 {
            let output = UniquePath.file(requested)
            if renamex_np(staged.path, output.path, UInt32(RENAME_EXCL)) == 0 { return output }
            let code = errno
            guard code == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        throw ArchiveError.tool("无法为压缩包选定未占用的文件名")
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
