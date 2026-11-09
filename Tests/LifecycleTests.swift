// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  退出流程：状态机、队列收尾、取消语义。
//
//  ⌘Q 本身在单元测试里按不到，可验证的是它背后的两件事：
//  - TerminationCoordinator 的状态迁移（什么时候放行、什么时候挂住、回调几次）
//  - ArchiveModel 的队列语义（等待时继续跑、取消时清队列、排空只通知一次）
//

import Foundation

/// 只记账的宿主：不碰真实队列，专测状态机
@MainActor
private final class StubTerminationHost: TerminationHost {
    var pendingJobCount = 0
    var isWritingScratch = false
    var onWorkDrained: (() -> Void)?
    private(set) var waitCount = 0
    private(set) var cancelCount = 0
    private(set) var resumeCount = 0

    func beginTerminationWait() { waitCount += 1 }
    func cancelWorkForTermination() { cancelCount += 1 }
    func resumeAfterAbortedTermination() { resumeCount += 1 }
}

/// 没有任务：⌘Q 直接放行，不弹窗不问人
func testTerminationWithoutWork() {
    print("退出 · 没有任务")
    MainActor.assumeIsolated {
        let host = StubTerminationHost()
        let coordinator = TerminationCoordinator()
        coordinator.host = host
        coordinator.defersPrompt = false
        var terminations = 0
        var aborts = 0
        coordinator.onTerminate = { terminations += 1 }
        coordinator.onAbort = { aborts += 1 }

        expect(coordinator.requestTermination() == .terminateNow, "队列为空时直接放行")
        expect(coordinator.promptCount == 0, "不弹确认框")
        expect(host.waitCount == 0, "不进入等待态")
        expect(terminations == 0 && aborts == 0, "不触发任何异步回调")
    }
}

/// 有任务：先挂住，等队列跑完再退；重复报告排空不会退两次
func testTerminationWaitsForQueue() {
    print("退出 · 等待完成后退出")
    MainActor.assumeIsolated {
        let host = StubTerminationHost()
        host.pendingJobCount = 3            // 1 个在跑 + 2 个排队
        let coordinator = TerminationCoordinator()
        coordinator.host = host
        coordinator.defersPrompt = false
        coordinator.ask = { .waitForCompletion }
        var terminations = 0
        var aborts = 0
        coordinator.onTerminate = { terminations += 1 }
        coordinator.onAbort = { aborts += 1 }

        expect(coordinator.requestTermination() == .terminateLater, "有任务时先挂住")
        expect(coordinator.promptCount == 1, "弹一次确认框")
        expect(host.waitCount == 1, "立刻进入等待态")
        expect(coordinator.state == .waiting, "状态机进入 waiting")
        expect(terminations == 0, "确认之前不退")

        // 还剩两个任务：排队中的继续跑，但还不能退
        host.pendingJobCount = 2
        coordinator.noteWorkDrained()
        expect(terminations == 0, "队列没跑完不退出")

        host.pendingJobCount = 0
        coordinator.noteWorkDrained()
        expect(terminations == 1, "全部跑完后执行退出")
        expect(coordinator.state == .terminating, "状态机进入 terminating")
        expect(terminations == 1 && aborts == 0, "只走退出，不走取消")

        // 迟到的排空信号 / 重复选择都不能再执行一次退出
        coordinator.noteWorkDrained()
        coordinator.apply(.waitForCompletion)
        coordinator.noteWorkDrained()
        expect(terminations == 1, "退出只执行一次", "实际 \(terminations) 次")
    }
}

/// 取消任务并退出：清队列、取消当前任务，收尾完成后才退
func testTerminationCancelAndQuit() {
    print("退出 · 取消任务并退出")
    MainActor.assumeIsolated {
        let host = StubTerminationHost()
        host.pendingJobCount = 2
        let coordinator = TerminationCoordinator()
        coordinator.host = host
        coordinator.defersPrompt = false
        coordinator.ask = { .cancelAndQuit }
        var terminations = 0
        coordinator.onTerminate = { terminations += 1 }

        expect(coordinator.requestTermination() == .terminateLater, "先挂住")
        expect(host.cancelCount == 1, "向模型下达取消")
        expect(coordinator.state == .cancelling, "状态机进入 cancelling")
        expect(terminations == 0, "当前任务还在收尾，不能立刻退出进程")

        host.pendingJobCount = 1
        coordinator.noteWorkDrained()
        expect(terminations == 0, "收尾期间不退")

        host.pendingJobCount = 0
        coordinator.noteWorkDrained()
        expect(terminations == 1, "收尾完成后退出")
        expect(coordinator.terminateCount == 1, "退出计数为 1")
    }
}

/// 继续使用：取消这次退出，并且恢复任务提交
func testTerminationKeepUsing() {
    print("退出 · 继续使用")
    MainActor.assumeIsolated {
        let host = StubTerminationHost()
        host.pendingJobCount = 1
        let coordinator = TerminationCoordinator()
        coordinator.host = host
        coordinator.defersPrompt = false
        coordinator.ask = { .keepUsing }
        var terminations = 0
        var aborts = 0
        coordinator.onTerminate = { terminations += 1 }
        coordinator.onAbort = { aborts += 1 }

        expect(coordinator.requestTermination() == .terminateLater, "先挂住")
        expect(coordinator.state == .idle, "回到 idle")
        expect(aborts == 1, "回复系统「不退了」")
        expect(host.resumeCount == 1, "恢复提交新任务")
        expect(terminations == 0, "没有执行退出")
        expect(host.onWorkDrained == nil, "不留悬挂的排空回调")

        // 之后还能正常再问一次；这次没有任务，直接放行
        host.pendingJobCount = 0
        expect(coordinator.requestTermination() == .terminateNow, "取消退出后仍可正常退出")
    }
}

/// 连按 ⌘Q：只弹一次窗，每次都被挂住，不会重复注册回调
func testTerminationRepeatedRequests() {
    print("退出 · 连按 ⌘Q")
    MainActor.assumeIsolated {
        let host = StubTerminationHost()
        host.pendingJobCount = 1
        let coordinator = TerminationCoordinator()
        coordinator.host = host
        // 弹窗仍然挂着：模拟「用户还在看确认框」的那段时间
        coordinator.defersPrompt = true
        var terminations = 0
        coordinator.onTerminate = { terminations += 1 }

        for _ in 0..<4 {
            expect(coordinator.requestTermination() == .terminateLater, "重复请求仍被挂住")
        }
        expect(coordinator.promptCount == 1, "确认框只弹一次", "实际 \(coordinator.promptCount)")
        expect(host.waitCount == 1, "不重复进入等待态")
        expect(terminations == 0, "弹窗期间不退")

        // 队列在弹窗期间自己跑完了：用户选「等待完成」后应立刻退出
        host.pendingJobCount = 0
        coordinator.apply(.waitForCompletion)
        expect(terminations == 1, "没有残留任务时立即退出")
    }
}

/// 等待期间队列排空，但预览还在写盘：等一小会儿再退，且不会永远等下去
func testTerminationWaitsForScratchBriefly() {
    print("退出 · 预览写入收尾")
    MainActor.assumeIsolated {
        let host = StubTerminationHost()
        host.pendingJobCount = 1
        let coordinator = TerminationCoordinator()
        coordinator.host = host
        coordinator.defersPrompt = false
        coordinator.ask = { .waitForCompletion }
        coordinator.jobPollInterval = 0.02
        coordinator.scratchPollInterval = 0.02
        coordinator.scratchGrace = 0.3
        var terminations = 0
        coordinator.onTerminate = { terminations += 1 }

        _ = coordinator.requestTermination()
        host.pendingJobCount = 0
        host.isWritingScratch = true
        coordinator.noteWorkDrained()
        expect(terminations == 0, "还有临时写入时不立刻退出")

        // 写入结束：下一次轮询就该退出
        host.isWritingScratch = false
        expect(waitUntil(3, { terminations == 1 }), "写入结束后退出")

        // 一直写不完也不会卡死：宽限期到了照常退出
        let stubborn = StubTerminationHost()
        stubborn.pendingJobCount = 1
        let second = TerminationCoordinator()
        second.host = stubborn
        second.defersPrompt = false
        second.ask = { .waitForCompletion }
        second.jobPollInterval = 0.02
        second.scratchPollInterval = 0.02
        second.scratchGrace = 0.1
        var secondTerminations = 0
        second.onTerminate = { secondTerminations += 1 }
        _ = second.requestTermination()
        stubborn.pendingJobCount = 0
        stubborn.isWritingScratch = true
        second.noteWorkDrained()
        expect(waitUntil(3, { secondTerminations == 1 }), "宽限期到点后照常退出，不无限卡住")
    }
}

/// 等待退出时不再接受新任务；当前任务收尾后回调恰好一次
func testTerminationRefusesNewJobs() {
    print("退出 · 拒绝新任务")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        let model = ArchiveModel()
        var release: (() -> Void)?
        var started = 0
        var finished = 0

        model.submitJob(title: "正在压缩", detail: "a.zip") { _ in
            started += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                release = { continuation.resume() }
            }
            finished += 1
            return .succeeded
        }
        expect(waitUntil(5, { started == 1 }), "第一个任务已开始")
        expect(model.pendingJobCount == 1, "队列里 1 个任务")

        model.beginTerminationWait()
        model.submitJob(title: "正在压缩", detail: "b.zip") { _ in
            started += 1
            return .succeeded
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        expect(started == 1, "等待退出期间新任务既不执行也不排队", "实际启动 \(started) 个")
        expect(model.pendingJobCount == 1, "队列没有增长", "实际 \(model.pendingJobCount)")

        var drained = 0
        model.onWorkDrained = { drained += 1 }
        release?()
        expect(waitUntil(5, { finished == 1 && model.pendingJobCount == 0 }), "当前任务已收尾")
        expect(drained == 1, "排空回调恰好一次", "实际 \(drained)")
        expect(model.onWorkDrained == nil, "回调用完即摘，不会重复触发")
        expect(!model.hasUnfinishedWork, "队列与写入都已归零")
        expect(model.isTerminating, "等待态保持到真正退出")
    }
}

/// 取消任务并退出：清掉排队任务、只让当前任务收尾、不启动下一个
func testTerminationCancelClearsQueue() {
    print("退出 · 取消时清空队列")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        let model = ArchiveModel()
        var started: [String] = []
        var release: (() -> Void)?

        model.submitJob(title: "a", detail: "a") { _ in
            started.append("a")
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                release = { continuation.resume() }
            }
            return .succeeded
        }
        model.submitJob(title: "b", detail: "b") { _ in
            started.append("b")
            return .succeeded
        }
        model.submitJob(title: "c", detail: "c") { _ in
            started.append("c")
            return .succeeded
        }
        expect(waitUntil(5, { started == ["a"] }), "第一个任务在跑，后两个排队")
        expect(model.pendingJobCount == 3, "队列 3 个", "实际 \(model.pendingJobCount)")

        var drained = 0
        model.onWorkDrained = { drained += 1 }
        model.cancelWorkForTermination()
        expect(model.pendingJobCount == 1, "排队的 b、c 已清空，只剩 a 在收尾",
               "实际 \(model.pendingJobCount)")

        release?()
        expect(waitUntil(5, { model.pendingJobCount == 0 }), "a 收尾后队列为空")
        expect(started == ["a"], "被清掉的排队任务没有偷偷启动", "实际 \(started)")
        expect(drained == 1, "排空回调恰好一次", "实际 \(drained)")
    }
}

/// 卡在密码输入上的任务：取消退出时必须放走 continuation，否则永远不结束
func testTerminationClearsPasswordWait() {
    print("退出 · 密码等待")
    MainActor.assumeIsolated {
        let model = ArchiveModel()
        model.passwordRequest = ArchiveModel.PasswordRequest(
            archive: URL(fileURLWithPath: "/tmp/secret.7z"), isRetry: false
        )
        model.cancelWorkForTermination()
        expect(model.passwordRequest == nil, "退出取消时关掉密码弹窗")
        expect(model.isTerminating, "退出态保持")
    }
}

/// 任务失败也要照常推进退出，不能因为结果是 failed 就卡在等待里
func testTerminationCompletesAfterFailure() {
    print("退出 · 任务失败")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        let model = ArchiveModel()
        var release: (() -> Void)?
        model.submitJob(title: "正在解压", detail: "bad.zip") { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                release = { continuation.resume() }
            }
            return .failed("模拟失败")
        }
        expect(waitUntil(5, { release != nil }), "任务已开始")

        model.beginTerminationWait()
        var drained = 0
        model.onWorkDrained = { drained += 1 }
        release?()
        expect(waitUntil(5, { drained == 1 }), "失败的任务同样触发排空")
        expect(model.pendingJobCount == 0, "队列已空")
    }
}

func runLifecycleTests() {
    testTerminationWithoutWork()
    testTerminationWaitsForQueue()
    testTerminationCancelAndQuit()
    testTerminationKeepUsing()
    testTerminationRepeatedRequests()
    testTerminationWaitsForScratchBriefly()
    testTerminationRefusesNewJobs()
    testTerminationCancelClearsQueue()
    testTerminationClearsPasswordWait()
    testTerminationCompletesAfterFailure()
}
