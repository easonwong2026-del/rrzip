// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Darwin
import Foundation

/// 主程序串行接管访达任务。文件认领在后台，账本准入和密码交互在主线程。
@MainActor
final class FinderTaskWorker {
    typealias AskPassword = @MainActor (URL, Bool) async -> String?
    typealias Feedback = @MainActor (FinderTaskReceipt, JobOutcome, FinderTaskRequest.Operation) -> Void

    private let queue: FinderTaskQueue
    private let ledger: FormalWriteLedger
    private let askPassword: AskPassword
    private let feedback: Feedback
    private let activity: @MainActor (TaskJob?) -> Void
    private let onError: @MainActor (Error) -> Void
    private let log: @Sendable (JobRecord) -> Void
    private var lease: FileHandle?
    private var watcher: (any DispatchSourceFileSystemObject)?
    private var parentWatcher: (any DispatchSourceFileSystemObject)?
    private(set) var isScanning = false
    private var needsScan = false
    private(set) var currentJob: TaskJob?
    private var progressID: UUID?
    private var passwordTask: Task<String?, Never>?

    init(queue: FinderTaskQueue = FinderTaskQueue(), ledger: FormalWriteLedger = .shared,
         askPassword: @escaping AskPassword,
         feedback: @escaping Feedback,
         activity: @escaping @MainActor (TaskJob?) -> Void = { _ in },
         onError: @escaping @MainActor (Error) -> Void = { _ in },
         log: @escaping @Sendable (JobRecord) -> Void = { FinderJobLog.append($0) }) {
        self.queue = queue
        self.ledger = ledger
        self.askPassword = askPassword
        self.feedback = feedback
        self.activity = activity
        self.onError = onError
        self.log = log
    }

    func start() {
        do {
            if lease == nil {
                guard let acquired = try queue.acquireWorker() else { return }
                try queue.recover()
                lease = acquired
            }
            if parentWatcher == nil {
                parentWatcher = try watch(queue.parent) { [weak self] in self?.ensureInboxWatch() }
            }
            try connectInboxWatch()
            requestScan()
        } catch {
            onError(error)
        }
    }

    private func watch(_ directory: URL, handler: @escaping @MainActor @Sendable () -> Void)
        throws -> any DispatchSourceFileSystemObject {
        let fd = try queue.openWatchDirectory(directory)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        parentWatcher?.cancel()
        parentWatcher = nil
    }

    func cancelCurrent() {
        guard let currentJob else { return }
        progressID = nil
        TaskRegistry.cancel(currentJob.id)
        passwordTask?.cancel()
    }

    private func connectInboxWatch() throws {
        if let watcher, queue.inboxIsCurrent(Int32(watcher.handle)) { return }
        watcher?.cancel()
        watcher = nil
        watcher = try watch(queue.inbox) { [weak self] in self?.inboxChanged() }
    }

    private func ensureInboxWatch() {
        if let watcher, queue.inboxIsCurrent(Int32(watcher.handle)) { return }
        do {
            try connectInboxWatch()
            requestScan()
        } catch {
            onError(error)
        }
    }

    private func inboxChanged() {
        guard let watcher else { return }
        if !watcher.data.intersection([.rename, .delete, .revoke]).isEmpty {
            ensureInboxWatch()
        } else {
            requestScan()
        }
    }

    private func requestScan() {
        needsScan = true
        guard !isScanning else { return }
        isScanning = true
        Task {
            defer { isScanning = false }
            while needsScan {
                needsScan = false
                await drain()
            }
        }
    }

    /// 测试用同一执行入口，不启动只用于真实应用的目录监听器。
    func drain() async {
        do {
            while let request = try await Task.detached(priority: .utility, operation: { [queue] in
                try queue.claimNext()
            }).value {
                await process(request)
            }
        } catch {
            onError(error)
        }
    }

    private func process(_ request: FinderTaskRequest) async {
        let op = request.operation
        let count = request.sources.count
        var receipt = FinderTaskReceipt(id: request.id, state: .running, totalCount: count, fraction: 0)
        guard let write = ledger.begin(.finderService, label: "访达\(op.verb) \(count) 项") else {
            receipt.state = .appQuitting
            receipt.errorCode = "appQuitting"
            receipt.message = "rrzip 正在退出，未执行访达任务"
            await report(receipt, outcome: JobOutcome(), operation: op)
            return
        }
        defer { ledger.end(write) }

        let started = Date()
        var outcome = JobOutcome()
        let jobID = UUID()
        // 此 ID 只在本进程使用，与持久化队列中的请求 ID 独立。
        try? TaskRegistry.claim(jobID)
        currentJob = TaskJob(id: jobID, title: "访达\(op.verb)",
                             detail: count == 1 ? request.sources[0].displayName : "\(count) 项")
        activity(currentJob)
        defer {
            progressID = nil
            TaskRegistry.release(jobID)
            currentJob = nil
            activity(nil)
        }
        await report(receipt, outcome: outcome, operation: op)

        do {
            try Self.checkContinuation(ledger, jobID: jobID)
            let access = try request.sources.map(Access.init)
            defer { for file in access { file.release() } }
            let urls = access.map(\.url)

            if op.isExtraction {
                let mode: FinderSettings.ExtractStrategy = op == .extractHere ? .here : .newFolder
                let plans = await Task.detached(priority: .utility) {
                    FinderJobPlanner.planExtraction(of: urls, mode: mode)
                }.value
                for plan in plans {
                    do {
                        let result = try await extract(plan, request: request, receipt: receipt, jobID: jobID)
                        outcome.succeeded.append(plan.archive.lastPathComponent)
                        outcome.destination = result.destination
                        outcome.skippedFiles += result.skipped
                        if mode == .newFolder { outcome.outputs.append(result.destination) }
                    } catch ArchiveError.cancelled {
                        throw ArchiveError.cancelled
                    } catch {
                        outcome.failed.append(.init(name: plan.archive.lastPathComponent, reason: error.localizedDescription))
                    }
                    await advance(&receipt, by: 1, outcome: outcome, operation: op)
                }
            } else {
                let groups = op == .compressEach ? urls.map { [$0] } : [urls]
                let format: FinderJobRunner.CompressionFormat = op == .compressSevenZip ? .sevenZip : .zip
                for files in groups {
                    let progress = progressCallback(receipt, units: files.count)
                    let result = try await Task.detached(priority: .utility) { [ledger] in
                        try Self.checkContinuation(ledger, jobID: jobID)
                        return try FinderJobRunner.compress(files, format: format, each: false,
                                                            jobID: jobID, onProgress: progress)
                    }.value
                    FinderJobRunner.append(result, to: &outcome)
                    await advance(&receipt, by: files.count, outcome: outcome, operation: op)
                }
            }
            receipt.state = outcome.failed.isEmpty ? .succeeded : .failed
            receipt.errorCode = outcome.failed.isEmpty ? nil : "archiveOperationFailed"
            receipt.message = FinderNoticeText.title(for: outcome, verb: op.verb)
        } catch ArchiveError.cancelled {
            receipt.state = .cancelled
            receipt.errorCode = "cancelled"
            receipt.message = "已取消访达\(op.verb)"
        } catch {
            receipt.state = .failed
            receipt.errorCode = "accessDenied"
            receipt.message = error.localizedDescription
            outcome.failed.append(.init(name: request.sources.first?.displayName ?? op.verb,
                                        reason: error.localizedDescription))
        }

        receipt.outputNames = outcome.outputs.map(\.lastPathComponent)
        if let reason = outcome.failed.first?.reason, !reason.isEmpty, receipt.errorCode == "archiveOperationFailed" {
            receipt.message = "\(receipt.message ?? op.verb) · \(String(reason.prefix(500)))"
        }
        let record = JobRecord(id: request.id.uuidString, op: op.rawValue, startedAt: started, finishedAt: Date(),
                               payload: .init(succeeded: outcome.succeeded, failed: outcome.failed.map(\.name),
                                              needsPassword: outcome.needsPassword, skippedFiles: outcome.skippedFiles,
                                              destination: outcome.destination?.path))
        await Task.detached(priority: .utility) { [log] in log(record) }.value
        await report(receipt, outcome: outcome, operation: op)
    }

    private func extract(_ plan: PlannedExtraction, request: FinderTaskRequest,
                         receipt: FinderTaskReceipt, jobID: UUID) async throws -> (destination: URL, skipped: Int) {
        var password: String?
        let intoNewFolder = request.operation == .extractToFolder
        while true {
            do {
                let attempt = password
                let progress = progressCallback(receipt, units: 1)
                return try await Task.detached(priority: .utility) { [ledger] in
                    try Self.checkContinuation(ledger, jobID: jobID)
                    return try FinderJobRunner.extract(plan, password: attempt, intoNewFolder: intoNewFolder,
                                                       jobID: jobID, onProgress: progress)
                }.value
            } catch ArchiveError.needsPassword {
                try Self.checkContinuation(ledger, jobID: jobID)
                progressID = nil
                var waiting = receipt
                waiting.state = .needsPassword
                waiting.message = "\(plan.archive.lastPathComponent) 需要密码"
                await report(waiting, outcome: JobOutcome(), operation: request.operation)
                try Self.checkContinuation(ledger, jobID: jobID)
                let retry = password != nil
                let prompt = Task { await askPassword(plan.archive, retry) }
                passwordTask = prompt
                let typed = await prompt.value
                passwordTask = nil
                guard let typed else {
                    throw ArchiveError.cancelled
                }
                try Self.checkContinuation(ledger, jobID: jobID)
                password = typed
                await report(receipt, outcome: JobOutcome(), operation: request.operation)
            }
        }
    }

    private nonisolated static func checkContinuation(_ ledger: FormalWriteLedger, jobID: UUID) throws {
        try TaskRegistry.checkCancellation(jobID)
        let gate = ledger.currentGate
        if gate == .cancelling || gate == .terminating { throw ArchiveError.cancelled }
    }

    private func progressCallback(_ receipt: FinderTaskReceipt, units: Int) -> @Sendable (Double) -> Void {
        let id = UUID()
        progressID = id
        currentJob?.fraction = nil
        activity(currentJob)
        return { [weak self] value in
            guard value.isFinite else { return }
            let fraction = (Double(receipt.completedCount) + Double(units) * min(max(value, 0), 1))
                / Double(receipt.totalCount)
            Task { @MainActor [weak self] in
                guard let self, self.progressID == id,
                      fraction > (self.currentJob?.fraction ?? -1) else { return }
                self.currentJob?.fraction = fraction
                self.activity(self.currentJob)
            }
        }
    }

    private func advance(_ receipt: inout FinderTaskReceipt, by count: Int, outcome: JobOutcome,
                         operation: FinderTaskRequest.Operation) async {
        progressID = nil
        receipt.completedCount += count
        receipt.fraction = Double(receipt.completedCount) / Double(max(1, receipt.totalCount))
        await report(receipt, outcome: outcome, operation: operation)
    }

    private func report(_ receipt: FinderTaskReceipt, outcome: JobOutcome,
                        operation: FinderTaskRequest.Operation) async {
        var updated = receipt
        updated.updatedAt = Date()
        let snapshot = updated
        do {
            try await Task.detached(priority: .utility) { [queue] in try queue.record(snapshot) }.value
            feedback(snapshot, outcome, operation)
        } catch {
            onError(error)
        }
    }

    private final class Access {
        let url: URL
        private var requiresStop = false

        init(_ ref: FinderFileRef) throws {
            if let bookmark = ref.bookmarkData {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, url.isFileURL, FinderFileRef(url: url).isValid else {
                    throw FinderTaskQueueError.invalidRequest
                }
                requiresStop = url.startAccessingSecurityScopedResource()
            } else {
                url = URL(fileURLWithPath: ref.path)
            }
        }

        deinit { release() }

        func release() {
            if requiresStop {
                url.stopAccessingSecurityScopedResource()
                requiresStop = false
            }
        }
    }
}
