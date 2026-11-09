// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  退出覆盖：原地编辑、访达服务这类「不经过队列的正式写入」。
//
//  这组用例只验一件事：⌘Q 时必须看见它们，并且只等不杀——
//  压缩包在退出流程走完之后仍然完整，才算真的安全。
//

import Foundation

/// 正式写入数直接读账本的宿主（访达服务没有 model）
@MainActor
private final class LedgerHost: TerminationHost {
    var pendingJobCount = 0
    var isWritingScratch = false
    var onWorkDrained: (() -> Void)?
    private(set) var waitCount = 0
    private(set) var cancelCount = 0

    var formalWrites: FormalWriteSummary { FormalWriteLedger.shared.summary() }

    func beginTerminationWait() { waitCount += 1 }
    func cancelWorkForTermination() { cancelCount += 1 }
    func resumeAfterAbortedTermination() {}
}

/// 包着真 model 的宿主：队列计数固定为 1（只为把协调器推进 waiting），
/// 其余状态与动作都落到真 model 上，`isTerminating` 这类行为才验得到。
@MainActor
private final class ModelHost: TerminationHost {
    let model: ArchiveModel
    var pendingJobCount = 1
    var isWritingScratch = false
    var onWorkDrained: (() -> Void)?
    var formalWrites: FormalWriteSummary { FormalWriteLedger.shared.summary() }

    init(_ model: ArchiveModel) { self.model = model }
    func beginTerminationWait() { model.beginTerminationWait() }
    func cancelWorkForTermination() { model.cancelWorkForTermination() }
    func resumeAfterAbortedTermination() { model.resumeAfterAbortedTermination() }
}

/// 计数可手调的宿主：用来验「宽限期管不到正式写入」
@MainActor
private final class CounterHost: TerminationHost {
    var pendingJobCount = 0
    var formalWrites = FormalWriteSummary()
    var isWritingScratch = false
    var onWorkDrained: (() -> Void)?

    func beginTerminationWait() {}
    func cancelWorkForTermination() {}
    func resumeAfterAbortedTermination() {}
}

/// 正式写入不能靠 5 秒宽限期「等不到就走」——那是预览缓存的规则
func testFormalWritesHaveNoGracePeriod() {
    print("退出 · 正式写入没有宽限期")
    MainActor.assumeIsolated {
        let host = CounterHost()
        host.formalWrites = FormalWriteSummary(inPlaceEdits: 1)
        let coordinator = TerminationCoordinator()
        coordinator.host = host
        coordinator.defersPrompt = false
        coordinator.ask = { .waitForCompletion }
        coordinator.jobPollInterval = 0.02
        coordinator.scratchGrace = 0.05
        var terminations = 0
        coordinator.onTerminate = { terminations += 1 }

        expect(coordinator.requestTermination() == .terminateLater, "有正式写入时先挂住")
        expect(coordinator.workload.formalWrites == 1, "工作负载里能看到正式写入")
        expect(!coordinator.workload.isPreviewOnly, "不是「只有预览缓存」")

        // 远超预览宽限期，仍然不许退
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        expect(terminations == 0, "超过预览宽限期也不退出", "实际退了 \(terminations) 次")
        expect(coordinator.state == .waiting, "仍在等待")

        host.formalWrites = FormalWriteSummary()
        expect(waitUntil(3, { terminations == 1 }), "写入结束后才退出")
    }
}

/// 原地添加过程中按 ⌘Q：等它写完，压缩包必须完整且包含新文件
func testInPlaceAddSurvivesQuit() {
    print("退出 · 原地添加")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        FormalWriteLedger.shared.reset()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("rrzip-add-exit-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let seed = folder.appendingPathComponent("seed.txt")
            try "seed\n".write(to: seed, atomically: true, encoding: .utf8)
            let archive = folder.appendingPathComponent("edit.zip")
            try SevenZip.create(at: archive, from: [seed], format: "zip",
                                password: nil, volume: nil)
            let added = folder.appendingPathComponent("added.bin")
            try Data(count: 4 * 1024 * 1024).write(to: added)

            let model = ArchiveModel()
            model.open(url: archive)
            expect(waitUntil(15, { model.current != nil }), "压缩包已打开")

            model.performAdd([added], to: archive, prefix: "")
            // 登记是同步的：调用返回这一刻按 ⌘Q 就必须能看见
            expect(FormalWriteLedger.shared.count == 1, "原地添加已登记为正式写入")

            let coordinator = TerminationCoordinator()
            coordinator.host = model
            coordinator.defersPrompt = false
            coordinator.ask = { .waitForCompletion }
            var terminations = 0
            coordinator.onTerminate = { terminations += 1 }

            expect(coordinator.requestTermination() == .terminateLater, "⌘Q 被识别，先挂住")
            expect(coordinator.workload.formalWrites == 1, "退出负载包含这次编辑")

            expect(waitUntil(120, { FormalWriteLedger.shared.isEmpty }), "添加已经写完")
            expect(waitUntil(5, { terminations == 1 }), "写完才执行退出")

            let entries = try SevenZip.list(archive)
            expect(entries.contains { $0.path == "added.bin" }, "新文件确实进包了",
                   "实际 \(entries.map(\.path))")
            expect(entries.contains { $0.path == "seed.txt" }, "原有条目还在")
            expect((try? SevenZip.verify(archive)) != nil, "压缩包完整可校验")
        } catch {
            expect(false, "原地添加退出 抛出异常", "\(error)")
        }

        try? fm.removeItem(at: folder)
        FormalWriteLedger.shared.reset()
    }
}

/// 原地删除过程中选「取消任务并退出」：不能终止正在改包的 7zz，只能等它收尾
func testInPlaceDeleteSurvivesCancelQuit() {
    print("退出 · 原地删除")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        FormalWriteLedger.shared.reset()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("rrzip-del-exit-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let seed = folder.appendingPathComponent("seed.txt")
            try "seed\n".write(to: seed, atomically: true, encoding: .utf8)
            let keep = folder.appendingPathComponent("keep.txt")
            try "keep\n".write(to: keep, atomically: true, encoding: .utf8)
            let archive = folder.appendingPathComponent("edit.zip")
            try SevenZip.create(at: archive, from: [seed, keep], format: "zip",
                                password: nil, volume: nil)

            let model = ArchiveModel()
            model.open(url: archive)
            expect(waitUntil(15, { model.current != nil }), "压缩包已打开")

            model.performDelete(["seed.txt"], from: archive, prefix: "")
            expect(FormalWriteLedger.shared.count == 1, "原地删除已登记为正式写入")

            let coordinator = TerminationCoordinator()
            coordinator.host = model
            coordinator.defersPrompt = false
            coordinator.ask = { .cancelAndQuit }
            var terminations = 0
            coordinator.onTerminate = { terminations += 1 }

            expect(coordinator.requestTermination() == .terminateLater, "⌘Q 被识别")
            expect(coordinator.state == .cancelling, "进入取消并退出")
            // 编辑不在队列里，取消只清队列；这次编辑本身必须等完
            expect(FormalWriteLedger.shared.count == 1, "取消没有把正在改包的 7zz 杀掉")

            expect(waitUntil(120, { FormalWriteLedger.shared.isEmpty }), "删除已经收尾")
            expect(waitUntil(5, { terminations == 1 }), "收尾后才执行退出")

            let entries = try SevenZip.list(archive)
            expect(!entries.contains { $0.path == "seed.txt" }, "条目已删除",
                   "实际 \(entries.map(\.path))")
            expect(entries.contains { $0.path == "keep.txt" }, "其他条目没被误伤")
            expect((try? SevenZip.verify(archive)) != nil, "压缩包完整可校验")
        } catch {
            expect(false, "原地删除退出 抛出异常", "\(error)")
        }

        try? fm.removeItem(at: folder)
        FormalWriteLedger.shared.reset()
    }
}

/// 访达「分别压缩」过程中选取消退出：两个 ZIP 都要完整，不能留半成品
func testFinderCompressEachDuringCancelQuit() {
    print("退出 · 访达分别压缩")
    MainActor.assumeIsolated {
        FormalWriteLedger.shared.reset()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("rrzip-svc-zip-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let a = folder.appendingPathComponent("a.bin")
            let b = folder.appendingPathComponent("b.txt")
            try Data(count: 8 * 1024 * 1024).write(to: a)
            try "b\n".write(to: b, atomically: true, encoding: .utf8)

            FinderService.compressEach([a, b])
            expect(FormalWriteLedger.shared.count == 1, "访达服务已登记为正式写入")

            let host = LedgerHost()
            let coordinator = TerminationCoordinator()
            coordinator.host = host
            coordinator.defersPrompt = false
            coordinator.ask = { .cancelAndQuit }
            var terminations = 0
            coordinator.onTerminate = { terminations += 1 }

            expect(coordinator.requestTermination() == .terminateLater, "⌘Q 被识别")
            expect(waitUntil(120, { FormalWriteLedger.shared.isEmpty }), "压缩跑完")
            expect(waitUntil(5, { terminations == 1 }), "跑完才退出")

            let zipA = folder.appendingPathComponent("a.zip")
            let zipB = folder.appendingPathComponent("b.zip")
            expect(fm.fileExists(atPath: zipA.path), "a.zip 已生成")
            expect(fm.fileExists(atPath: zipB.path), "b.zip 已生成")
            expect((try? Tar.list(zipA))?.count == 1, "a.zip 内容完整")
            expect((try? Tar.list(zipB))?.count == 1, "b.zip 内容完整")

            // 暂存文件必须清干净：.a-XXXX.zip / .b-XXXX.zip
            let leftovers = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix(".a-") || $0.hasPrefix(".b-") }
            expect(leftovers.isEmpty, "没有残留的暂存文件", "\(leftovers)")
        } catch {
            expect(false, "访达分别压缩退出 抛出异常", "\(error)")
        }

        try? fm.removeItem(at: folder)
        FormalWriteLedger.shared.reset()
    }
}

/// 访达「解压到此处」过程中按 ⌘Q：等解压结束，产物齐全
func testFinderExtractDuringQuit() {
    print("退出 · 访达解压")
    MainActor.assumeIsolated {
        FormalWriteLedger.shared.reset()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("rrzip-svc-extract-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let archive = folder.appendingPathComponent("样例.zip")
            try fm.copyItem(at: fixtures.appendingPathComponent("basic.zip"), to: archive)

            FinderService.extract([archive])
            expect(FormalWriteLedger.shared.count == 1, "访达解压已登记为正式写入")

            let host = LedgerHost()
            let coordinator = TerminationCoordinator()
            coordinator.host = host
            coordinator.defersPrompt = false
            coordinator.ask = { .waitForCompletion }
            var terminations = 0
            coordinator.onTerminate = { terminations += 1 }

            expect(coordinator.requestTermination() == .terminateLater, "⌘Q 被识别")
            expect(waitUntil(120, { FormalWriteLedger.shared.isEmpty }), "解压结束")
            expect(waitUntil(5, { terminations == 1 }), "结束才退出")

            expect(fm.fileExists(atPath: folder.appendingPathComponent("说明.txt").path),
                   "根目录条目已解出")
            expect(fm.fileExists(atPath: folder.appendingPathComponent("照片/002.jpg").path),
                   "子目录条目已解出")
        } catch {
            expect(false, "访达解压退出 抛出异常", "\(error)")
        }

        try? fm.removeItem(at: folder)
        FormalWriteLedger.shared.reset()
    }
}

/// 退出提示要跟行为一致：正式写入说「等它完成」，只有预览时才提 5 秒上限
func testTerminationMessageMatchesBehavior() {
    print("退出 · 提示文案")
    MainActor.assumeIsolated {
        let previewOnly = TerminationCoordinator.Workload(previewWrites: true).message
        expect(previewOnly.contains("5 秒"), "只有预览时说明 5 秒上限", previewOnly)
        expect(previewOnly.contains("不影响"), "说明不会影响正式文件", previewOnly)

        let formal = TerminationCoordinator.Workload(inPlaceEdits: 2).message
        expect(formal.contains("会等它写完"), "原地编辑说明会等写完", formal)
        expect(formal.contains("毁掉"), "说明中途终止的后果", formal)
        expect(!formal.contains("5 秒"), "正式写入不提宽限期", formal)

        let jobs = TerminationCoordinator.Workload(jobs: 1).message
        expect(jobs.contains("取消"), "有队列任务时说明取消的边界", jobs)
    }
}

/// 冷启动直接被访达服务唤起时，窗口还没 attach；账本是进程级的，仍要能看见
func testWorkloadSeesFormalWritesWithoutHost() {
    print("退出 · 没有宿主时的正式写入")
    MainActor.assumeIsolated {
        FormalWriteLedger.shared.reset()
        guard let token = FormalWriteLedger.shared.begin(.finderService, label: "冷启动访达服务") else {
            expect(false, "空闲状态却拒绝了写入登记")
            return
        }
        defer {
            FormalWriteLedger.shared.end(token)
            FormalWriteLedger.shared.reset()
        }

        let coordinator = TerminationCoordinator()      // host 故意留空
        coordinator.defersPrompt = false
        coordinator.ask = { .keepUsing }
        expect(coordinator.hasUnfinishedWork, "没有 host 也能看见访达服务")
        expect(coordinator.workload.finderServices == 1, "归类到访达服务")
        expect(coordinator.requestTermination() == .terminateLater, "冷启动也会先挂住")

        // 选「继续使用」后回到可提交状态，账本不受影响
        expect(coordinator.state == .idle, "取消退出后回到 idle")
        expect(FormalWriteLedger.shared.count == 1, "账本里的写入还在")
    }
}

/// 退出等待 / 取消期间，正式写入入口必须整体拒绝；选「继续使用」后恢复
func testExitWaitingRejectsNewFormalWrites() {
    print("退出 · 拒绝新的正式写入")
    MainActor.assumeIsolated {
        FormalWriteLedger.shared.reset()
        ScratchUsage.shared.reset()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("rrzip-gate-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let seed = folder.appendingPathComponent("seed.txt")
            try "seed\n".write(to: seed, atomically: true, encoding: .utf8)
            let archive = folder.appendingPathComponent("edit.zip")
            try SevenZip.create(at: archive, from: [seed], format: "zip",
                                password: nil, volume: nil)
            let added = folder.appendingPathComponent("added.bin")
            try Data(count: 1024 * 1024).write(to: added)
            let serviceSource = folder.appendingPathComponent("svc.bin")
            try Data(count: 1024 * 1024).write(to: serviceSource)

            let model = ArchiveModel()
            model.open(url: archive)
            expect(waitUntil(15, { model.current != nil }), "压缩包已打开")

            // 借一个「队列里还有任务」的宿主，把协调器推进 waiting
            let host = ModelHost(model)
            let coordinator = TerminationCoordinator()
            coordinator.host = host
            coordinator.defersPrompt = false
            coordinator.ask = { .waitForCompletion }
            coordinator.jobPollInterval = 5
            expect(coordinator.requestTermination() == .terminateLater, "有任务时挂住")
            expect(coordinator.state == .waiting, "进入 waiting")
            expect(FormalWriteLedger.shared.currentGate == .waiting, "写入闸门已关")

            // 1. 原地添加 / 删除：拒绝，连 7zz 都不启动
            model.performAdd([added], to: archive, prefix: "")
            expect(FormalWriteLedger.shared.count == 0, "等待退出时拒绝原地添加")
            model.performDelete(["seed.txt"], from: archive, prefix: "")
            expect(FormalWriteLedger.shared.count == 0, "等待退出时拒绝原地删除")

            // 2. 访达服务：三个入口都拒绝，且不产出文件
            let each = FinderService.compressEach([serviceSource])
            let merged = FinderService.compressMerged([serviceSource])
            let extract = FinderService.extract([archive])
            var eachResult: FinderCompressOutcome?
            var mergedResult: FinderCompressResult?
            var extractResult: FinderExtractOutcome?
            Task { eachResult = await each.value }
            Task { mergedResult = await merged.value }
            Task { extractResult = await extract.value }
            expect(waitUntil(5, {
                eachResult?.rejected == true && mergedResult?.rejected == true
                    && extractResult?.rejected == true
            }), "访达服务的三个入口都被拒绝")
            expect(!fm.fileExists(atPath: folder.appendingPathComponent("svc.bin.zip").path),
                   "没有被拒绝还硬压出来的 ZIP")
            expect(FormalWriteLedger.shared.count == 0, "账本里没有残留登记")

            // 3. 取消并退出同样拒绝
            let cancelling = TerminationCoordinator()
            cancelling.host = host
            cancelling.defersPrompt = false
            cancelling.ask = { .cancelAndQuit }
            cancelling.jobPollInterval = 5
            _ = cancelling.requestTermination()
            expect(cancelling.state == .cancelling, "进入 cancelling")
            expect(FormalWriteLedger.shared.currentGate == .cancelling, "取消期间闸门也是关的")
            model.performAdd([added], to: archive, prefix: "")
            expect(FormalWriteLedger.shared.count == 0, "取消并退出时拒绝新的原地编辑")

            // 4. 用户改主意：下一次退出里选「继续使用」，闸门重新打开，入口恢复
            let keep = TerminationCoordinator()
            keep.host = host
            keep.defersPrompt = false
            keep.ask = { .keepUsing }
            _ = keep.requestTermination()
            expect(keep.state == .idle, "回到 idle")
            expect(FormalWriteLedger.shared.currentGate == .idle, "继续使用后闸门打开")
            expect(!model.isTerminating, "队列恢复接收任务")
            model.performAdd([added], to: archive, prefix: "")
            expect(FormalWriteLedger.shared.count == 1, "继续使用后可以正常登记")
            expect(waitUntil(120, { FormalWriteLedger.shared.isEmpty }), "这次编辑正常完成")
        } catch {
            expect(false, "写入准入 抛出异常", "\(error)")
        }

        try? fm.removeItem(at: folder)
        FormalWriteLedger.shared.reset()
    }
}

/// 真正退出前的闸门是单向的：sealed 之后不会再打开
func testTerminatingGateStaysClosed() {
    print("退出 · 闸门单向关闭")
    MainActor.assumeIsolated {
        FormalWriteLedger.shared.reset()
        FormalWriteLedger.shared.setGate(.terminating)
        expect(FormalWriteLedger.shared.currentGate == .terminating, "进入 terminating")
        expect(FormalWriteLedger.shared.begin(.inPlaceEdit, label: "晚到的编辑") == nil,
               "终止后拒绝登记")
        FormalWriteLedger.shared.setGate(.idle)
        expect(FormalWriteLedger.shared.currentGate == .terminating, "sealed 不会被改回 idle")
        FormalWriteLedger.shared.reset()
        expect(FormalWriteLedger.shared.currentGate == .idle, "reset 只为测试复位")
    }
}

func runExitCoverageTests() {
    testFormalWritesHaveNoGracePeriod()
    testInPlaceAddSurvivesQuit()
    testInPlaceDeleteSurvivesCancelQuit()
    testFinderCompressEachDuringCancelQuit()
    testFinderExtractDuringQuit()
    testTerminationMessageMatchesBehavior()
    testWorkloadSeesFormalWritesWithoutHost()
    testExitWaitingRejectsNewFormalWrites()
    testTerminatingGateStaysClosed()
}
