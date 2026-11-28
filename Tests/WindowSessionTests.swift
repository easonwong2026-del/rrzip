// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Foundation
import Carbon

func runWindowSessionTests() {
    testWindowRoutingAndSharedStash()
    testWindowCacheRetirement()
    testWindowTermination()
    testClosingWindowIsolatedCancellation()
    testEncryptedStashAcrossWindows()
    testPackSameNamedArchivesAcrossWindows()
    testOpenDocumentEvent()
}

private func testOpenDocumentEvent() {
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                       eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil,
                                       returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
    let first = fixtures.appendingPathComponent("basic.zip")
    let second = fixtures.appendingPathComponent("bundle.tgz")
    let files = NSAppleEventDescriptor.list()
    files.insert(NSAppleEventDescriptor(fileURL: first), at: 1)
    files.insert(NSAppleEventDescriptor(int32: 1), at: 2)
    files.insert(NSAppleEventDescriptor(fileURL: second), at: 3)
    event.setParam(files, forKeyword: AEKeyword(keyDirectObject))
    let paths = openDocumentURLs(event).map { ScratchUsage.canonical($0.path) }
    expect(paths == [first, second].map { ScratchUsage.canonical($0.path) },
           "系统打开文档事件按顺序转交每个有效文件 URL")
}

private func testPackSameNamedArchivesAcrossWindows() {
    guard SevenZip.isAvailable else { return }
    print("多窗口 · 打包同名归档的共享暂存")
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let registry = WindowSessionRegistry()
        let a = registry.makeModel()
        let b = registry.makeModel()
        registry.register(a)
        registry.register(b)
        defer {
            registry.unregister(a.sessionID)
            registry.unregister(b.sessionID)
        }
        let root = fixtures.appendingPathComponent("shared-pack")
        do {
            for (index, model) in [a, b, a].enumerated() {
                let folder = root.appendingPathComponent("\(index)")
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let source = folder.appendingPathComponent("same.txt")
                try Data("source \(index)".utf8).write(to: source)
                let archive = folder.appendingPathComponent("logs.tar")
                try Tar.create(at: archive, from: [source], format: "tar")
                model.addToStash(archive: archive, path: "same.txt", size: 8)
            }
            let output = root.appendingPathComponent("packed.zip")
            b.packStash(to: output)
            expect(waitUntil(15, { b.pendingJobCount == 0 }), "一个窗口打包三个跨窗口条目")
            let entries = try InProcessArchive.list(output)
            expect(entries.count == 3 && Set(entries.map(\.name)).count == 3, "同名归档和文件仍生成三个不同的名称")
            let unpacked = root.appendingPathComponent("unpacked")
            try ArchiveService.extract(output, entries: [], to: unpacked, password: nil)
            let contents = try entries.map { try String(contentsOf: unpacked.appendingPathComponent($0.path), encoding: .utf8) }
            expect(Set(contents) == Set(["source 0", "source 1", "source 2"]), "打包保留每个归档的原始内容")
        } catch { expect(false, "跨窗口打包", "\(error)") }
    }
}

private func testWindowRoutingAndSharedStash() {
    print("多窗口 · 规范路径路由、跨窗口暂存与导出")
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let registry = WindowSessionRegistry()
        let a = registry.makeModel()
        let b = registry.makeModel()
        let zip = fixtures.appendingPathComponent("basic.zip")
        let tar = fixtures.appendingPathComponent("bundle.tgz")
        let alias = fixtures.appendingPathComponent("window-route-alias.zip")
        let destination = fixtures.appendingPathComponent("window-stash-export")
        let previousLayout = a.stashLayout
        defer {
            a.stashLayout = previousLayout
            registry.unregister(a.sessionID)
            registry.unregister(b.sessionID)
        }
        do {
            try fm.createSymbolicLink(at: alias, withDestinationURL: zip)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            expect(registry.route(zip) == .newWindow, "没有窗口时打开新窗口")
            registry.register(a)
            registry.register(b)
            expect(registry.route(zip, preferred: b.sessionID) == .reuse(b.sessionID), "优先复用来源首页")
            expect(registry.route(zip) == .reuse(a.sessionID), "没有来源时复用活跃首页")
            expect(registry.route(zip, newlyCreated: [a.sessionID]) == .reuse(b.sessionID),
                   "优先复用空闲的已有窗，不为同批系统预建窗挤走它")
            a.openInSession(zip)
            expect(registry.route(alias) == .focus(a.sessionID), "加载期间同一规范路径也只聚焦一次")
            expect(registry.route(tar) == .reuse(b.sessionID), "当前窗口正在加载时复用另一首页")
            b.openInSession(tar)
            expect(registry.route(fixtures.appendingPathComponent("secret.7z")) == .newWindow, "已有归档的窗口保留并打开新窗")
            expect(waitUntil(10, { a.current != nil && b.current != nil }), "两窗口各自读完归档")
            expect(registry.route(alias) == .focus(a.sessionID), "加载完成后仍去重聚焦")
            registry.activate(b.sessionID)
            expect(registry.activeModel === b, "记录当前焦点窗口")
            let finderJob = TaskJob(id: UUID(), title: "访达压缩", detail: "项目", fraction: 0.5)
            registry.showFinderJob(finderJob)
            expect(a.finderJob == nil && b.finderJob == finderJob, "访达任务卡显示在焦点窗口")
            registry.activate(a.sessionID)
            expect(a.finderJob == finderJob && b.finderJob == nil, "切换焦点同步迁移访达进度卡")
            registry.showFinderJob(nil)
            expect(a.finderJob == nil, "完成时移除活跃进度卡")

            a.selection = ["说明.txt"]
            a.addSelectionToStash()
            b.selection = ["readme.txt"]
            b.addSelectionToStash()
            expect(a.stash == b.stash && a.stash.count == 2, "A 和 B 分别加入同一份暂存")
            a.stashLayout = .flat
            expect(b.stashLayout == .flat, "暂存布局在窗口之间同步")
            registry.unregister(a.sessionID)
            expect(registry.activeModel === b && a.windowClosed, "关闭焦点窗口后登记回退到另一窗口")
            expect(b.stash.count == 2, "关闭来源窗口不会清掉共享暂存")
            b.exportStash(to: destination)
            b.addToStash(archive: zip, path: "带 空格.txt", size: 6)
            expect(waitUntil(15, { b.pendingJobCount == 0 }), "单次任务导出两个窗口的暂存")
            expect(fm.fileExists(atPath: destination.appendingPathComponent("说明.txt").path)
                   && fm.fileExists(atPath: destination.appendingPathComponent("readme.txt").path),
                   "共享暂存真实导出两个来源")
            expect(a.stash == b.stash && b.stash.map(\.path) == ["带 空格.txt"],
                   "导出只清除该任务的快照，保留其他后加入的条目")
        } catch { expect(false, "窗口路由和共享暂存", "\(error)") }
    }
}

private func testClosingWindowIsolatedCancellation() {
    print("多窗口 · 关窗只取消当前会话")
    MainActor.assumeIsolated {
        let registry = WindowSessionRegistry()
        let a = registry.makeModel()
        let b = registry.makeModel()
        registry.register(a)
        registry.register(b)
        var cancelled: Set<UUID> = []
        for model in [a, b] {
            model.submitJob(title: "测试任务", detail: "") { id in
                while !TaskRegistry.wasCancelled(id) {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                cancelled.insert(id)
                return .cancelled
            }
        }
        let aID = a.job?.id
        let bID = b.job?.id
        registry.unregister(a.sessionID)
        expect(registry.model(a.sessionID) == nil && registry.pendingJobCount == 2,
               "关闭会话立即注销路由，正在收尾的任务仍计入退出等待")
        expect(waitUntil(6, { cancelled.count == 1 && registry.pendingJobCount == 1 }),
               "已关闭窗口的任务收尾完成")
        expect(aID.map(cancelled.contains) == true && bID.map(TaskRegistry.wasCancelled) == false,
               "另一窗口的子进程归属未收到取消")
        registry.unregister(b.sessionID)
        expect(waitUntil(6, { registry.pendingJobCount == 0 }), "最后一个窗口任务正常释放")
    }
}

private func testEncryptedStashAcrossWindows() {
    guard SevenZip.isAvailable else { return }
    print("多窗口 · 跨窗口导出已解锁的暂存项")
    MainActor.assumeIsolated {
        let registry = WindowSessionRegistry()
        let a = registry.makeModel()
        let b = registry.makeModel()
        registry.register(a)
        registry.register(b)
        let previousLayout = b.stashLayout
        defer {
            b.stashLayout = previousLayout
            registry.unregister(a.sessionID)
            registry.unregister(b.sessionID)
        }
        let archive = fixtures.appendingPathComponent("secret.7z")
        let output = fixtures.appendingPathComponent("encrypted-shared-stash")
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            b.stashLayout = .flat
            a.openInSession(archive)
            expect(waitUntil(8, { a.passwordRequest != nil }), "密码提示属于打开归档的窗口")
            a.submitPassword("pw123")
            expect(waitUntil(8, { a.current != nil }), "来源窗口解锁归档")
            b.addToStash(archive: archive, path: "说明.txt", size: 6)
            expect(registry.stash.passwords[archive.path] == "pw123", "暂存保留来源窗口提供的密码")
            registry.unregister(a.sessionID)
            b.exportStash(to: output)
            expect(waitUntil(8, { b.pendingJobCount == 0 }), "来源窗关闭后共享暂存仍能完成导出")
            expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("说明.txt").path),
                   "跨窗导出复用来源归档的内存密码", b.errorMessage ?? b.status)
            expect(registry.stash.passwords.isEmpty, "最后一个暂存条目移除时清除其暂存密码")
        } catch { expect(false, "跨窗口加密暂存", "\(error)") }
    }
}

private func testWindowCacheRetirement() {
    print("多窗口 · 关闭后只回收自己的预览缓存")
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let registry = WindowSessionRegistry()
        let a = registry.makeModel()
        let b = registry.makeModel()
        registry.register(a)
        registry.register(b)
        defer {
            b.clearStash()
            registry.unregister(a.sessionID)
            registry.unregister(b.sessionID)
        }
        let archive = fixtures.appendingPathComponent("basic.zip")
        a.openInSession(archive)
        b.openInSession(archive)
        guard waitUntil(10, { a.current != nil && b.current != nil }),
              let entry = a.entries.first(where: { $0.path == "照片/002.jpg" }) else {
            expect(false, "窗口缓存样本读取完毕")
            return
        }
        var first: URL?
        var second: URL?
        a.payloadURL(for: entry) { first = $0 }
        b.payloadURL(for: entry) { second = $0 }
        guard waitUntil(10, { first != nil && second != nil }), let first, let second else {
            expect(false, "两窗口生成预览副本")
            return
        }
        expect(first != second, "每个窗口使用独立缓存路径")
        b.addToStash(archive: first, path: "held.txt", size: 5)
        registry.unregister(a.sessionID)
        expect(a.cachedPayloadCount == 0, "关闭时释放该窗口缓存索引")
        expect(fm.fileExists(atPath: first.path), "共享暂存仍持有的来源留到释放后")
        expect(b.cachedPayloadCount == 1 && fm.fileExists(atPath: second.path), "关闭 A 不删除 B 的预览副本")
        b.clearStash()
        expect(!fm.fileExists(atPath: first.path), "最后一个暂存持有释放后回收关闭窗口的缓存")
        expect(fm.fileExists(atPath: second.path), "继续保留 B 的缓存")
    }
}

private func testWindowTermination() {
    print("多窗口 · 统一等待和取消退出")
    MainActor.assumeIsolated {
        let ledger = FormalWriteLedger.shared
        ledger.reset()
        defer { ledger.reset() }
        let registry = WindowSessionRegistry()
        let a = registry.makeModel()
        let b = registry.makeModel()
        let c = registry.makeModel()
        for model in [a, b, c] { registry.register(model) }

        var cancelledIDs: Set<UUID> = []
        for model in [a, b] {
            model.submitJob(title: "test", detail: "") { id in
                while !TaskRegistry.wasCancelled(id) {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                cancelledIDs.insert(id)
                return .cancelled
            }
        }
        var promptEnded = false
        Task {
            let value = await c.askPassword(for: fixtures.appendingPathComponent("secret.7z"), wrong: false)
            promptEnded = value == nil
        }
        expect(waitUntil(5, { c.passwordRequest != nil }), "第三窗口进入密码交互")
        expect(registry.pendingJobCount == 3, "聚合两个后台任务和一个独立密码交互")
        ScratchUsage.shared.beginWork()
        expect(registry.isWritingScratch, "聚合进程中的预览写入")
        ScratchUsage.shared.endWork()

        let coordinator = TerminationCoordinator()
        coordinator.host = registry
        coordinator.defersPrompt = false
        coordinator.ask = { .keepUsing }
        expect(coordinator.requestTermination() == .terminateLater, "任一窗口有任务时拦截退出")
        expect(!a.isTerminating && !b.isTerminating && !c.isTerminating, "继续使用恢复所有窗口")
        expect(cancelledIDs.isEmpty && c.passwordRequest != nil, "继续使用保留任务与密码交互")

        var finderCancels = 0
        registry.cancelFinderTask = { finderCancels += 1 }
        coordinator.ask = { .cancelAndQuit }
        expect(coordinator.requestTermination() == .terminateLater, "退出时先统一发出取消")
        expect(waitUntil(6, { coordinator.terminateCount == 1 && promptEnded }), "等待两任务和密码交互全部收尾")
        expect(cancelledIDs.count == 2 && registry.pendingJobCount == 0, "两个窗口的任务都收到取消")
        expect(finderCancels == 1, "进程级访达执行器仅取消一次")
    }
}
