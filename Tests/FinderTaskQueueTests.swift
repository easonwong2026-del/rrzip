// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Foundation

private func newFinderQueue() -> FinderTaskQueue {
    FinderTaskQueue(root: fixtures.appendingPathComponent("finder-queue-\(UUID().uuidString)", isDirectory: true))
}

private func makeFinderRequest(_ operation: FinderTaskRequest.Operation = .extractHere,
                               urls: [URL]? = nil) -> FinderTaskRequest {
    FinderTaskRequest(operation: operation, sources: (urls ?? [fixtures.appendingPathComponent("basic.zip")]).map {
        FinderFileRef(url: $0)
    })
}

private func queueFile(_ id: UUID, in folder: URL) -> URL {
    folder.appendingPathComponent(id.uuidString).appendingPathExtension("json")
}

func runFinderTaskQueueTests() {
    testQueuePublishAndClaim()
    testQueueRejectsInvalidInput()
    testQueueSelectionBookmarkBudget()
    testQueueExpiryAndRecovery()
    testWorkerRunsOperations()
    testWorkerWakesForNewQueueFiles()
    testWorkerPasswordAndQuit()
    testWorkerStopsStartingFilesOnCancelQuit()
    testWorkerCancelsRealProcesses()
    testWorkerCancelsPasswordPrompt()
}

private func testQueueSelectionBookmarkBudget() {
    print("访达队列 · 多选书签大小降级")
    let queue = newFinderQueue()
    let urls = (0..<FinderTaskQueue.maxSources).map {
        fixtures.appendingPathComponent("deep/目录/文件-\($0).txt")
    }
    let bookmark = Data(repeating: 1, count: 3072)
    do {
        expect(try queue.enqueueSelection(.compressZip, urls: urls, bookmark: { _ in bookmark }),
               "100 项书签超出队列上限时仍能提交合法路径")
        let request = try queue.claimNext()
        expect(request?.sources.map(\.path) == urls.map(\.path), "降级保留路径和选择顺序")
        expect(request?.sources.allSatisfy { $0.bookmarkData == nil } == true, "仅超限时移除所有大书签")
        expect(try queue.enqueueSelection(.compressZip, urls: [urls[0]], bookmark: { _ in bookmark }),
               "小请求正常入队")
        expect(try queue.claimNext()?.sources.first?.bookmarkData == bookmark, "小请求保留原书签")

        let existing = fixtures.appendingPathComponent("basic.zip")
        expect(try queue.enqueueSelection(.extractHere, urls: [existing]), "真实文件使用默认书签构建")
        let bookmarkData = try queue.claimNext()?.sources.first?.bookmarkData
        expect(bookmarkData?.isEmpty == false, "默认构建保存真实的 minimal bookmark")

        let longPaths = (0..<FinderTaskQueue.maxSources).map {
            fixtures.appendingPathComponent(String(repeating: "tail/", count: 550) + "\($0).txt")
        }
        do {
            try queue.enqueueSelection(.compressZip, urls: longPaths, bookmark: { _ in bookmark })
            expect(false, "路径自身超限时应拒绝入队")
        } catch FinderTaskQueueError.tooLarge {
            expect(true, "移除书签后仍验证队列编码上限")
        }
        expect(try queue.claimNext() == nil, "超限重试失败不会留下半条请求")
    } catch { expect(false, "多选书签大小降级", "\(error)") }
}

private func testQueuePublishAndClaim() {
    print("访达队列 · 原子投递和并发认领")
    let queue = newFinderQueue()
    let request = makeFinderRequest()
    do {
        expect(try queue.enqueue(request), "首次提交保留整个请求")
        expect(try !queue.enqueue(request), "待认领时同一 UUID 去重")
        expect(try queue.receipt(for: request.id)?.state == .queued, "投递立即有排队回执")
        let files = try FileManager.default.contentsOfDirectory(atPath: queue.inbox.path)
        expect(files == [queueFile(request.id, in: queue.inbox).lastPathComponent], "发布后只有完整最终文件")
        let loaded = try JSONDecoder().decode(FinderTaskRequest.self, from: Data(contentsOf: queueFile(request.id, in: queue.inbox)))
        expect(loaded == request, "最终文件保留完整内容")

        MainActor.assumeIsolated {
            var claims: [FinderTaskRequest]?
            Task {
                claims = await withTaskGroup(of: FinderTaskRequest?.self) { group in
                    for _ in 0..<12 { group.addTask { try? queue.claimNext() } }
                    var results: [FinderTaskRequest] = []
                    for await result in group {
                        if let result { results.append(result) }
                    }
                    return results
                }
            }
            expect(waitUntil(8, { claims != nil }), "所有并发认领都返回")
            expect(claims == [request], "并发认领只有一个执行者")
        }

        expect(try !queue.enqueue(request), "已认领的 UUID 不再投递")
        try queue.record(.init(id: request.id, state: .succeeded, completedCount: 1, totalCount: 1))
        expect(try queue.receipt(for: request.id)?.state == .succeeded, "终态回执落盘")
        expect(!FileManager.default.fileExists(atPath: queueFile(request.id, in: queue.claimed).path),
               "终态后清除认领文件")
        expect(try !queue.enqueue(request), "终态回执继续阻止重复执行")
        try queue.record(.init(id: request.id, state: .running))
        expect(try queue.receipt(for: request.id)?.state == .succeeded, "终态不能被旧进度覆盖")
    } catch { expect(false, "队列并发测试", "\(error)") }
}

private func testQueueRejectsInvalidInput() {
    print("访达队列 · 非法、超限与软链拒绝")
    let queue = newFinderQueue()
    let fm = FileManager.default
    let request = makeFinderRequest()
    do {
        let primary = try queue.acquireWorker()
        expect(primary != nil, "可独占认领执行者锁")
        expect(try queue.acquireWorker() == nil, "第二个执行者不可中断第一份")
        try primary?.close()
        expect(try queue.acquireWorker() != nil, "退出后允许新的执行者")

        var unsupported = request
        unsupported.version = 999
        do {
            _ = try queue.enqueue(unsupported)
            expect(false, "应拒绝未知协议版本")
        } catch FinderTaskQueueError.unsupportedVersion {
            expect(true, "未知协议版本明确拒绝")
        }

        let tooMany = FinderTaskRequest(operation: .compressEach,
                                        sources: Array(repeating: request.sources[0], count: FinderTaskQueue.maxSources + 1))
        do {
            _ = try queue.enqueue(tooMany)
            expect(false, "应拒绝超出来源数量")
        } catch FinderTaskQueueError.tooLarge {
            expect(true, "来源数量上限生效")
        }

        var largeRef = request.sources[0]
        largeRef.bookmarkData = Data(count: FinderTaskQueue.maxBytes)
        let large = FinderTaskRequest(operation: .extractHere, sources: [largeRef])
        do {
            _ = try queue.enqueue(large)
            expect(false, "应拒绝超大请求")
        } catch FinderTaskQueueError.tooLarge {
            expect(true, "请求字节数上限生效")
        }

        let malformedID = UUID()
        try Data("not a request".utf8).write(to: queueFile(malformedID, in: queue.inbox))
        let forgedID = UUID()
        try JSONEncoder().encode(request).write(to: queueFile(forgedID, in: queue.inbox))
        let versionID = request.id
        try JSONEncoder().encode(unsupported).write(to: queueFile(versionID, in: queue.inbox))
        let oversizedID = UUID()
        try Data(count: FinderTaskQueue.maxBytes + 1).write(to: queueFile(oversizedID, in: queue.inbox))
        let aliasID = UUID()
        let target = fixtures.appendingPathComponent("finder-queue-link-target")
        let untouched = Data("keep".utf8)
        try untouched.write(to: target)
        try fm.createSymbolicLink(at: queueFile(aliasID, in: queue.inbox), withDestinationURL: target)
        expect(try queue.claimNext() == nil, "只存在非法项目时没有可执行请求")
        for id in [malformedID, forgedID, versionID, oversizedID, aliasID] {
            expect(try queue.receipt(for: id)?.state == .failed, "非法请求有明确失败回执")
        }
        expect(try Data(contentsOf: target) == untouched, "软链校验不读取或改写目标")

        let invalid = makeFinderRequest(.compressZip, urls: [fixtures.appendingPathComponent("bad\nname")])
        do {
            _ = try queue.enqueue(invalid)
            expect(false, "应拒绝带控制分隔符的来源")
        } catch FinderTaskQueueError.invalidRequest {
            expect(true, "非法来源拒绝投递")
        }

        let aliasRoot = fixtures.appendingPathComponent("finder-queue-directory-link")
        try fm.createSymbolicLink(at: aliasRoot, withDestinationURL: queue.root)
        do {
            _ = try FinderTaskQueue(root: aliasRoot).enqueue(request)
            expect(false, "应拒绝用软链指向队列目录")
        } catch FinderTaskQueueError.unsafeLocation {
            expect(true, "根目录的 lstat 类型检查生效")
        }
    } catch { expect(false, "队列防护测试", "\(error)") }
}

private func testQueueExpiryAndRecovery() {
    print("访达队列 · 过期、崩溃恢复及清理")
    let queue = newFinderQueue()
    let now = Date()
    var stale = makeFinderRequest()
    stale.createdAt = now.addingTimeInterval(-FinderTaskQueue.expiry - 1)
    let interrupted = makeFinderRequest()
    let previous = makeFinderRequest()
    do {
        try queue.enqueue(stale)
        expect(try queue.claimNext(now: now) == nil, "过期请求不会认领执行")
        expect(try queue.receipt(for: stale.id)?.state == .expired, "超过 10 分钟写过期回执")
        expect(!FileManager.default.fileExists(atPath: queueFile(stale.id, in: queue.inbox).path),
               "过期文件移出待处理目录")

        try queue.enqueue(interrupted)
        expect(try queue.claimNext()?.id == interrupted.id, "可准备上一进程的遗留认领")
        try queue.record(.init(id: interrupted.id, state: .running, completedCount: 1, totalCount: 2))
        try queue.enqueue(previous)
        expect(try queue.claimNext()?.id == previous.id, "可准备旧终态回执")
        try queue.record(.init(id: previous.id, state: .succeeded,
                               updatedAt: now.addingTimeInterval(-FinderTaskQueue.retention - 1)))

        let lease = try queue.acquireWorker()
        expect(lease != nil, "重启恢复持有执行者锁")
        defer { try? lease?.close() }
        try queue.recover(now: now)
        let restarted = try queue.receipt(for: interrupted.id)
        expect(restarted?.state == .interrupted && restarted?.completedCount == 1, "崩溃任务保留进度并标记中断")
        expect(try !queue.enqueue(interrupted), "崩溃任务不自动重写用户文件")
        expect(try queue.claimNext() == nil, "认领目录清理后不重跑")
        expect(try queue.receipt(for: previous.id) == nil, "24 小时以上的终态回执已清理")
        expect(try queue.receipt(for: stale.id)?.state == .expired, "仍有效的终态回执保留")
    } catch { expect(false, "队列恢复测试", "\(error)") }
}

private func testWorkerRunsOperations() {
    print("访达队列 · 真实压缩与解压")
    let queue = newFinderQueue()
    let fm = FileManager.default
    let root = fixtures.appendingPathComponent("finder-task-output", isDirectory: true)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let here = root.appendingPathComponent("here.zip")
        let newFolder = root.appendingPathComponent("new-folder.zip")
        let original = fixtures.appendingPathComponent("basic.zip")
        try fm.copyItem(at: original, to: here)
        try fm.copyItem(at: original, to: newFolder)
        let existing = root.appendingPathComponent("说明.txt")
        let keep = Data("keep existing".utf8)
        try keep.write(to: existing)
        let existingNested = root.appendingPathComponent("照片/城市/001.jpg")
        try fm.createDirectory(at: existingNested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try keep.write(to: existingNested)
        let fileA = root.appendingPathComponent("work-a.txt")
        let fileB = root.appendingPathComponent("work-b.txt")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)
        var requests = [
            makeFinderRequest(.extractHere, urls: [here]),
            makeFinderRequest(.extractToFolder, urls: [newFolder]),
            makeFinderRequest(.compressZip, urls: [fileA]),
            makeFinderRequest(.compressEach, urls: [fileA, fileB])
        ]
        if SevenZip.isAvailable { requests.append(makeFinderRequest(.compressSevenZip, urls: [fileA])) }
        for request in requests { try queue.enqueue(request) }

        MainActor.assumeIsolated {
            let ledger = FormalWriteLedger()
            var statuses: [UUID: FinderTaskReceipt] = [:]
            var outcomes: [UUID: JobOutcome] = [:]
            var activeCount = 0
            let worker = FinderTaskWorker(queue: queue, ledger: ledger, askPassword: { _, _ in nil },
                                          feedback: { receipt, result, _ in
                if receipt.state == .running { activeCount = max(activeCount, ledger.count(of: .finderService)) }
                if receipt.state.isTerminal {
                    statuses[receipt.id] = receipt
                    outcomes[receipt.id] = result
                }
            }, log: { _ in })
            var drained = false
            Task {
                await worker.drain()
                drained = true
            }
            expect(waitUntil(15, { drained }), "主程序执行器在后台清空访达队列")
            expect(activeCount == 1 && ledger.isEmpty, "执行登记为正式写入，结束后注销")
            expect(statuses.count == requests.count, "所有操作都写入终态")
            for request in requests {
                expect(statuses[request.id]?.state == .succeeded, "\(request.operation.rawValue) 成功")
                expect(statuses[request.id]?.fraction == 1, "成功任务的进度完成")
            }
            expect(outcomes[requests[0].id]?.skippedFiles == 2, "解压到此处计数同名跳过，包括已有目录内的文件")
            expect(statuses[requests[0].id]?.outputNames == [], "解压到此处不报告跳转产物")
            expect(statuses[requests[1].id]?.outputNames == ["new-folder"], "解到文件夹回传产物名称")
            expect(statuses[requests[3].id]?.outputNames.count == 2, "分别压缩回传两个产物")
        }
        expect(try Data(contentsOf: existing) == keep, "解压到此处保留旧文件")
        expect(try Data(contentsOf: existingNested) == keep, "合并已有目录时保留嵌套旧文件")
        expect(fm.fileExists(atPath: root.appendingPathComponent("照片/002.jpg").path), "合并已有目录时写入新文件")
        expect(fm.fileExists(atPath: root.appendingPathComponent("new-folder/说明.txt").path), "新文件夹真实解压")
        let outputs = try fm.contentsOfDirectory(atPath: root.path)
        expect(outputs.contains("work-a.zip") && outputs.contains("work-a 2.zip") && outputs.contains("work-b.zip"),
               "ZIP 发布避让并行请求的同名输出")
        if SevenZip.isAvailable {
            let output = root.appendingPathComponent("work-a.7z")
            expect(try InProcessArchive.list(output).map(\.path) == ["work-a.txt"], "真正生成可读 7Z")
        }
    } catch { expect(false, "队列执行测试", "\(error)") }
}

private func testWorkerCancelsRealProcesses() {
    print("访达队列 · 取消真实 tar / 7zz 并清理暂存")
    let fm = FileManager.default
    let root = fixtures.appendingPathComponent("finder-task-cancel-live")
    let inputs = root.appendingPathComponent("inputs")
    let source = inputs.appendingPathComponent("large-input")
    let archive = root.appendingPathComponent("large.tar")
    do {
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        fm.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 384 * 1024 * 1024)
        try handle.close()
        try Tar.create(at: archive, from: [source], format: "tar")

        try MainActor.assumeIsolated {
            let ledger = FormalWriteLedger.shared
            ledger.reset()
            defer { ledger.reset() }
            let model = ArchiveModel()
            var operations: [(FinderTaskRequest.Operation, URL, URL)] = [
                (.extractHere, archive, root.appendingPathComponent(source.lastPathComponent)),
                (.extractToFolder, archive, root.appendingPathComponent("large"))
            ]
            if SevenZip.isAvailable {
                operations.append((.compressSevenZip, source, source.appendingPathExtension("7z")))
            }
            for (operation, input, output) in operations {
                ledger.reset()
                let queue = newFinderQueue()
                let request = makeFinderRequest(operation, urls: [input])
                try queue.enqueue(request)
                let worker = FinderTaskWorker(queue: queue, ledger: ledger, askPassword: { _, _ in nil },
                    feedback: { _, _, _ in }, activity: { model.finderJob = $0 }, log: { _ in })
                model.cancelFinderTask = { worker.cancelCurrent() }
                var drained = false
                Task {
                    await worker.drain()
                    drained = true
                }
                let running = waitUntil(6, interval: 0.001) {
                    guard let id = model.finderJob?.id else { return false }
                    return TaskRegistry.hasProcess(for: id)
                }
                expect(running, "\(operation.rawValue) 的真实引擎进程与任务卡使用同一 ID")
                let job = model.finderJob
                expect(job?.id != nil && job?.id != request.id, "子进程 ID 独立于持久化请求")
                expect(job?.detail == input.lastPathComponent, "任务卡显示当前源文件")
                if operation == .compressSevenZip {
                    expect(waitUntil(5, interval: 0.001, { model.finderJob?.fraction != nil }),
                           "真实 7zz 进度抵达访达任务卡")
                }
                if operation == .extractToFolder {
                    let coordinator = TerminationCoordinator()
                    coordinator.host = model
                    coordinator.ask = { .cancelAndQuit }
                    coordinator.defersPrompt = false
                    expect(coordinator.requestTermination() == .terminateLater, "⌘Q 等待正在解压的访达任务")
                    expect(coordinator.state == .cancelling, "取消并退出通过模型取消访达进程")
                    expect(waitUntil(8, { drained && coordinator.terminateCount == 1 }), "收尾和回执完成后退出")
                    model.resumeAfterAbortedTermination()
                } else {
                    model.cancelFinderTask?()
                    expect(waitUntil(8, { drained }), "进度卡取消后执行器收尾")
                }
                expect(try queue.receipt(for: request.id)?.state == .cancelled, "真实进程取消写入取消回执")
                expect(ledger.isEmpty && model.finderJob == nil && worker.currentJob == nil,
                       "取消后释放账本并移除进度卡")
                expect(job.map { !TaskRegistry.hasProcess(for: $0.id) } == true, "退出后的子进程不再登记")
                expect(!fm.fileExists(atPath: output.path), "取消不发布本项的半成品")
                let siblings = try fm.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
                expect(!siblings.contains { $0.hasPrefix(".rrzip-") || $0.hasPrefix("..rrzip-") },
                       "取消清理归档暂存文件和目录")
            }
        }
    } catch { expect(false, "真实访达进程取消", "\(error)") }
}

private func testWorkerCancelsPasswordPrompt() {
    guard SevenZip.isAvailable else { return }
    print("访达队列 · 取消暂停等待密码的任务")
    let queue = newFinderQueue()
    let request = makeFinderRequest(.extractToFolder, urls: [fixtures.appendingPathComponent("secret.7z")])
    MainActor.assumeIsolated {
        do {
            try queue.enqueue(request)
            let model = ArchiveModel()
            let ledger = FormalWriteLedger()
            let worker = FinderTaskWorker(queue: queue, ledger: ledger,
                                          askPassword: { await model.askPassword(for: $0, wrong: $1) },
                                          feedback: { _, _, _ in }, log: { _ in })
            var drained = false
            Task {
                await worker.drain()
                drained = true
            }
            expect(waitUntil(8, { model.passwordRequest != nil }), "加密归档打开真实模型密码提示")
            worker.cancelCurrent()
            expect(waitUntil(8, { drained }), "取消终止等待密码的访达任务")
            expect(model.passwordRequest == nil && ledger.isEmpty, "取消只需关闭当前任务的密码提示并注销写入")
            expect(try queue.receipt(for: request.id)?.state == .cancelled, "等待密码取消写入终态回执")
        } catch { expect(false, "取消暂停等待密码的任务", "\(error)") }
    }
}

private func testWorkerPasswordAndQuit() {
    print("访达队列 · 密码衔接及退出拒绝")
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let folder = fixtures.appendingPathComponent("finder-queue-locked", isDirectory: true)
        let archive = folder.appendingPathComponent("locked.7z")
        let queue = newFinderQueue()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if SevenZip.isAvailable {
                try fm.copyItem(at: fixtures.appendingPathComponent("secret.7z"), to: archive)
                let request = makeFinderRequest(.extractToFolder, urls: [archive])
                try queue.enqueue(request)
                let ledger = FormalWriteLedger()
                var inputs: [Bool] = []
                var recorded = false
                let worker = FinderTaskWorker(queue: queue, ledger: ledger, askPassword: { url, wrong in
                    recorded = (try? queue.receipt(for: request.id)?.state) == .needsPassword &&
                        url == archive && ledger.count(of: .finderService) == 1
                    inputs.append(wrong)
                    return wrong ? "pw123" : "incorrect"
                }, feedback: { _, _, _ in }, log: { _ in })
                var drained = false
                Task {
                    await worker.drain()
                    drained = true
                }
                expect(waitUntil(12, { drained }), "加密归档没有中断队列")
                expect(inputs == [false, true], "旧密码错后由主程序重新询问")
                expect(recorded, "询问前已持久化 needsPassword 且保持正式写入登记")
                expect(try queue.receipt(for: request.id)?.state == .succeeded, "正确密码后原任务继续并成功")
                expect(fm.fileExists(atPath: folder.appendingPathComponent("locked/说明.txt").path), "加密 7Z 真实解出")
                expect(ledger.isEmpty, "密码解压完成后释放退出保护")
            }

            let denied = makeFinderRequest(.compressZip, urls: [folder.appendingPathComponent("no-work")])
            try queue.enqueue(denied)
            let closed = FormalWriteLedger()
            closed.setGate(.cancelling)
            let worker = FinderTaskWorker(queue: queue, ledger: closed, askPassword: { _, _ in nil },
                                          feedback: { _, _, _ in }, log: { _ in })
            var drained = false
            Task {
                await worker.drain()
                drained = true
            }
            expect(waitUntil(8, { drained }), "退出接管时仍能写终态回执")
            expect(try queue.receipt(for: denied.id)?.state == .appQuitting, "退出接管拒绝启动新的访达任务")
            expect(closed.isEmpty && !fm.fileExists(atPath: folder.appendingPathComponent("no-work.zip").path),
                   "被拒绝的访达任务没有打开进程或写出产物")
        } catch { expect(false, "访达队列密码与退出测试", "\(error)") }
    }
}

private func testWorkerWakesForNewQueueFiles() {
    print("访达队列 · 文件事件唤醒已启动的主程序")
    let queue = newFinderQueue()
    let source = fixtures.appendingPathComponent("finder-watcher-source.txt")
    do {
        try Data("watcher".utf8).write(to: source)
        let request = makeFinderRequest(.compressZip, urls: [source])
        MainActor.assumeIsolated {
            let ledger = FormalWriteLedger()
            var completed = Set<UUID>()
            var errors: [String] = []
            let worker = FinderTaskWorker(queue: queue, ledger: ledger, askPassword: { _, _ in nil },
                                          feedback: { receipt, _, _ in
                if receipt.state == .succeeded { completed.insert(receipt.id) }
            }, onError: { errors.append($0.localizedDescription) }, log: { _ in })
            worker.start()
            defer { worker.stopWatching() }
            guard waitUntil(8, { !worker.isScanning }) else {
                expect(false, "启动扫描完成后再测试文件事件")
                return
            }
            do {
                try queue.enqueue(request)
            } catch {
                expect(false, "投递文件事件夹具", "\(error)")
                return
            }
            expect(waitUntil(8, { completed.contains(request.id) }), "空闲时通过目录写入事件自动执行新请求")
            expect((try? queue.receipt(for: request.id)?.state) == .succeeded, "监听执行的终态已落盘")
            for directory in [queue.inbox, queue.root] {
                guard waitUntil(8, { !worker.isScanning }) else {
                    expect(false, "执行器完成前不替换测试队列")
                    return
                }
                do {
                    let backup = directory.deletingLastPathComponent().appendingPathComponent("old-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: directory, to: backup)
                    let next = makeFinderRequest(.compressZip, urls: [source])
                    try queue.enqueue(next)
                    expect(try queue.acquireWorker() == nil, "目录替换后执行者仍保持排他锁")
                    expect(waitUntil(8, { completed.contains(next.id) }), "重建 \(directory.lastPathComponent) 后仍能自动接管")
                } catch {
                    expect(false, "重建目录并投递", "\(error)")
                }
            }
            expect(errors.isEmpty, "目录监听没有报错")
        }
    } catch { expect(false, "监听测试准备", "\(error)") }
}

private func testWorkerStopsStartingFilesOnCancelQuit() {
    print("访达队列 · 退出取消与竞态")
    let queue = newFinderQueue()
    let folder = fixtures.appendingPathComponent("finder-queue-cancel-boundary", isDirectory: true)
    let fm = FileManager.default
    MainActor.assumeIsolated {
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let first = folder.appendingPathComponent("first.txt")
            let second = folder.appendingPathComponent("second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            let batch = makeFinderRequest(.compressEach, urls: [first, second])
            try queue.enqueue(batch)
            let ledger = FormalWriteLedger()
            let worker = FinderTaskWorker(queue: queue, ledger: ledger, askPassword: { _, _ in nil },
                                          feedback: { receipt, _, _ in
                if receipt.state == .running, receipt.completedCount == 1 { ledger.setGate(.cancelling) }
            }, log: { _ in })
            var drained = false
            Task {
                await worker.drain()
                drained = true
            }
            expect(waitUntil(8, { drained }), "取消退出后批量请求收尾")
            let result = try queue.receipt(for: batch.id)
            expect(result?.state == .cancelled && result?.completedCount == 1, "取消发生在两个文件之间时保留进度")
            expect(fm.fileExists(atPath: folder.appendingPathComponent("first.zip").path) &&
                   !fm.fileExists(atPath: folder.appendingPathComponent("second.zip").path),
                   "已完成的压缩保留，取消后不启动下一项")

            guard SevenZip.isAvailable else { return }
            let locked = folder.appendingPathComponent("unlock-race.7z")
            try fm.copyItem(at: fixtures.appendingPathComponent("secret.7z"), to: locked)
            let request = makeFinderRequest(.extractToFolder, urls: [locked])
            try queue.enqueue(request)
            ledger.setGate(.idle)
            let passwordWorker = FinderTaskWorker(queue: queue, ledger: ledger, askPassword: { _, _ in
                ledger.setGate(.cancelling)
                return "pw123"
            }, feedback: { _, _, _ in }, log: { _ in })
            drained = false
            Task {
                await passwordWorker.drain()
                drained = true
            }
            expect(waitUntil(8, { drained }), "返回密码与退出信号同时发生时能收尾")
            expect(try queue.receipt(for: request.id)?.state == .cancelled, "退出接管后不采用刚返回的正确密码")
            expect(ledger.isEmpty && !fm.fileExists(atPath: folder.appendingPathComponent("unlock-race").path),
                   "取消后的密码流程不写目标目录并释放账本")
        } catch { expect(false, "取消边界测试", "\(error)") }
    }
}
