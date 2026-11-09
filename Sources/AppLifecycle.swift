// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  AppLifecycle.swift
//  rrzip
//
//  退出协调：⌘Q 不再一刀切地结束进程，先看队列里还有没有活。
//
//  「关窗口」和「退出」是两件事：
//  - 关窗口只是收窗：进程继续跑，任务、缓存、暂存区都留着
//    （`applicationShouldTerminateAfterLastWindowClosed` 返回 false）。
//  - ⌘Q 才进这里：没有任务直接退；有任务就弹窗问「等 / 取消 / 继续用」。
//
//  这里只放状态机，不弹 NSAlert、不直接调 NSApp：
//  弹窗与 `reply(toApplicationShouldTerminate:)` 由 AppDelegate 注入，
//  队列语义才能在测试里跑真的（见 Tests/LifecycleTests.swift）。
//

import Foundation

/// 退出流程对模型的全部要求。实现见 ArchiveModel 的扩展。
@MainActor
protocol TerminationHost: AnyObject {
    /// 正在执行 + 排队等待的任务数
    var pendingJobCount: Int { get }
    /// 是否有预览解压、缩略图渲染这类不归队列管的临时写入
    var isWritingScratch: Bool { get }
    /// 进入退出等待：从此不再接受新的后台任务
    func beginTerminationWait()
    /// 取消当前任务、清空尚未执行的队列
    func cancelWorkForTermination()
    /// 用户改主意了：恢复提交
    func resumeAfterAbortedTermination()
    /// 队列排空时回调一次（由模型在 finishJob 里触发）
    var onWorkDrained: (() -> Void)? { get set }
}

/// 退出状态机：`idle → waiting → terminating` 或 `idle → cancelling → terminating`。
///
/// 防的就是这几个老问题：
/// - 连按 ⌘Q 弹出一摞一样的确认框；
/// - 等待退出时重复注册回调，真正的退出被回调两次；
/// - 队列清了却没人执行退出；
/// - 取消之后排队的任务又自己启动了。
///
/// `terminateNow` 的路径不经过状态机——交给 AppKit 直接退，
/// 只有「先问用户 / 先等收尾」才需要 `reply(toApplicationShouldTerminate:)`。
@MainActor
final class TerminationCoordinator {
    /// 一次退出请求的结论：现在就能退，还是先挂起等回话
    enum Decision: Equatable {
        case terminateNow
        case terminateLater
    }

    /// 弹窗上的三个选项
    enum Choice: Equatable {
        case waitForCompletion
        case cancelAndQuit
        case keepUsing
    }

    enum State: String, Equatable {
        case idle
        case waiting
        case cancelling
        case terminating
    }

    static let shared = TerminationCoordinator()

    private(set) var state: State = .idle
    /// 弹过几次确认框（测试用：连按 ⌘Q 不该涨）
    private(set) var promptCount = 0
    /// 真正执行了几次退出（测试用：只该有一次）
    private(set) var terminateCount = 0
    /// 回复了几次「继续使用」（测试用）
    private(set) var abortCount = 0

    weak var host: TerminationHost?

    /// 弹窗：由 AppDelegate 注入。没有注入时按最安全的选择处理（继续使用）。
    var ask: () -> Choice = { .keepUsing }
    /// 是否把弹窗推迟到下一个主循环。
    ///
    /// 生产必须为 true：`applicationShouldTerminate` 要先返回 `.terminateLater`，
    /// 模态框才不会被系统的终止流程吞掉。测试置 false，同步拿到选择结果。
    var defersPrompt = true
    /// 真正退出：NSApp.reply(toApplicationShouldTerminate: true)
    var onTerminate: () -> Void = {}
    /// 取消这次退出：NSApp.reply(toApplicationShouldTerminate: false)
    var onAbort: () -> Void = {}

    /// 队列还有任务时的兜底轮询间隔。正常路径是模型排空后回调，
    /// 轮询只防「回调漏了 → 退出永远不执行」。
    var jobPollInterval: TimeInterval = 0.5
    /// 队列空了但预览解压还在写盘时的重查间隔
    var scratchPollInterval: TimeInterval = 0.1
    /// 等预览写入收尾的上限。超了也照常退出——不能因为一段预览把人卡在应用里
    var scratchGrace: TimeInterval = 5

    /// 队列排空后开始计时的时刻：宽限期只算「等预览写入」的这段时间，
    /// 不能把前面压缩跑的一分钟也算进去，否则宽限期永远早就过了。
    private var scratchWaitStartedAt: Date?
    private var pollScheduled = false

    init() {}

    /// 队列之外是否还有活。用于「要不要拦下这次退出」的判断。
    var hasUnfinishedWork: Bool {
        guard let host else { return false }
        return host.pendingJobCount > 0 || host.isWritingScratch
    }

    // MARK: - 入口

    /// ⌘Q / 菜单退出。返回 `.terminateNow` 时调用方直接放行。
    func requestTermination() -> Decision {
        switch state {
        case .waiting, .cancelling, .terminating:
            // 已经有流程在跑：不弹第二个窗，也不注册第二个回调。
            // 这里返回 later 是为了让重复的 ⌘Q 仍然被挂住，而不是绕过队列退出。
            return .terminateLater
        case .idle:
            break
        }

        guard hasUnfinishedWork else { return .terminateNow }

        state = .waiting
        promptCount += 1
        // 弹窗还开着的时候就先禁掉新任务：用户已经按了 ⌘Q，
        // 这期间再往队列里塞东西，等待完成后退出就不再是「已有任务的收尾」。
        host?.beginTerminationWait()
        if defersPrompt {
            Task { @MainActor in
                // 让 applicationShouldTerminate 先返回，再弹模态框
                guard self.state == .waiting else { return }
                self.apply(self.ask())
            }
        } else {
            apply(ask())
        }
        return .terminateLater
    }

    /// 用户选择的结果。测试直接调这个，生产由弹窗回调。
    func apply(_ choice: Choice) {
        guard state == .waiting else { return }

        switch choice {
        case .keepUsing:
            state = .idle
            abortCount += 1
            host?.onWorkDrained = nil
            host?.resumeAfterAbortedTermination()
            onAbort()
        case .waitForCompletion:
            // 模型已在 requestTermination 里进入等待态，这里只等队列自己跑完
            armDrainCallback()
            checkDrained()
        case .cancelAndQuit:
            state = .cancelling
            // 清队列 + 取消当前任务；返回后立刻判一次，可能本来就没有活
            host?.cancelWorkForTermination()
            armDrainCallback()
            checkDrained()
        }
    }

    /// 模型在 `finishJob` 里排空队列时调用。幂等：状态不对就什么都不做。
    func noteWorkDrained() {
        checkDrained()
    }

    // MARK: - 排空判断

    private func checkDrained() {
        guard state == .waiting || state == .cancelling else { return }

        if let host, host.pendingJobCount > 0 {
            // 队列任务的收尾有明确回调；轮询只是兜住「回调丢了」这一种情况
            schedulePoll(after: jobPollInterval)
            return
        }

        if let host, host.isWritingScratch {
            // 预览解压 / 缩略图不归队列管，也没有完成回调：短间隔重查，
            // 但不能无限等——超过宽限期就照常退出。
            let started = scratchWaitStartedAt ?? Date()
            scratchWaitStartedAt = started
            if Date().timeIntervalSince(started) < scratchGrace {
                schedulePoll(after: scratchPollInterval)
                return
            }
        }

        finishTermination()
    }

    private func schedulePoll(after interval: TimeInterval) {
        guard !pollScheduled else { return }
        pollScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
            self.pollScheduled = false
            self.checkDrained()
        }
    }

    /// 模型排空队列时会主动回调，别只靠轮询
    private func armDrainCallback() {
        host?.onWorkDrained = { [weak self] in
            self?.noteWorkDrained()
        }
    }

    private func finishTermination() {
        guard state == .waiting || state == .cancelling else { return }
        state = .terminating
        host?.onWorkDrained = nil
        terminateCount += 1
        onTerminate()
    }

    /// 测试用：不影响生产单例
    func reset() {
        guard state != .terminating else { return }
        state = .idle
        promptCount = 0
        terminateCount = 0
        abortCount = 0
        scratchWaitStartedAt = nil
        pollScheduled = false
        host?.onWorkDrained = nil
    }
}
