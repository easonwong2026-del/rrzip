// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  FormalWriteLedger.swift
//  rrzip
//
//  跟踪队列之外、需要退出协调等待的操作。
//  原地编辑和访达服务必须等写完，批量任务可以取消后清理。
//  登记要发生在派发之前，防止 ⌘Q 漏掉刚提交的任务。
//

import Foundation

/// 写入准入。退出流程一旦接管，就不该再有新的正式写入挤进来：
/// 用户已经按了「等待完成后退出」，队列却还在变长，那道等待就没有终点。
///
/// 由 `TerminationCoordinator` 统一设置，入口只读：
/// - idle：正常，允许登记
/// - waiting：退出等待中，拒绝
/// - cancelling：取消并退出中，拒绝
/// - terminating：正在退出，永久关闭（不会回到 idle）
enum FormalWriteGate: String, Sendable, Equatable {
    case idle
    case waiting
    case cancelling
    case terminating

    var acceptsWrites: Bool { self == .idle }
}

/// 正式写入的细分。退出提示要分别说清「在改哪个包」和「在给谁压缩」。
struct FormalWriteSummary: Equatable, Sendable {
    var inPlaceEdits = 0
    var finderServices = 0
    var batchExtracts = 0
    var batchVerifications = 0

    var total: Int { inPlaceEdits + finderServices + batchExtracts + batchVerifications }
    var isEmpty: Bool { total == 0 }
}

/// 一项正在写入用户文件的工作
struct FormalWrite: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// 原地增删压缩包条目：改的是用户的原包
        case inPlaceEdit
        /// 访达右键服务：压缩 / 解压
        case finderService
        case batchExtract
        case batchVerify

        var title: String {
            switch self {
            case .inPlaceEdit: return "原地编辑压缩包"
            case .finderService: return "访达服务"
            case .batchExtract: return "批量解压"
            case .batchVerify: return "批量校验"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let label: String
}

/// 进程内的正式写入登记处。线程安全：登记与注销可能来自任意线程。
final class FormalWriteLedger: @unchecked Sendable {
    static let shared = FormalWriteLedger()

    private let lock = NSLock()
    private var entries: [UUID: FormalWrite] = [:]
    private var batchCancellations: [UUID: @MainActor @Sendable () -> Void] = [:]
    /// 退出流程的写入准入。默认 open，退出协调接管后关闭。
    private var gate: FormalWriteGate = .idle
    /// 归零时回调一次（可选）。没有它也能退出，只是要多等一个轮询周期。
    private var emptyHandler: (@Sendable () -> Void)?

    /// 数量归零时回调。设置方负责切回主线程。
    func onEmpty(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); emptyHandler = handler; lock.unlock()
    }

    var currentGate: FormalWriteGate {
        lock.lock(); defer { lock.unlock() }
        return gate
    }

    /// 由退出协调调用。`terminating` 是单向的，之后不再接受任何写入。
    func setGate(_ next: FormalWriteGate) {
        lock.lock()
        if gate == .terminating { lock.unlock(); return }
        gate = next
        lock.unlock()
    }

    /// 登记一项正式写入。返回 nil 表示**被退出流程拒绝**——
    /// 调用方必须据此放弃操作，不能先干活再补登记。
    func begin(_ kind: FormalWrite.Kind, label: String,
               onCancel: (@MainActor @Sendable () -> Void)? = nil) -> UUID? {
        let write = FormalWrite(id: UUID(), kind: kind, label: label)
        lock.lock()
        guard gate.acceptsWrites else {
            lock.unlock()
            return nil
        }
        entries[write.id] = write
        batchCancellations[write.id] = onCancel
        lock.unlock()
        return write.id
    }

    @MainActor
    func cancelBatches() {
        let cancellations = lock.withLock { Array(batchCancellations.values) }
        for cancel in cancellations { cancel() }
    }

    func end(_ id: UUID) {
        var becameEmpty = false
        var handler: (@Sendable () -> Void)?
        lock.lock()
        batchCancellations.removeValue(forKey: id)
        if entries.removeValue(forKey: id) != nil, entries.isEmpty {
            becameEmpty = true
            handler = emptyHandler
        }
        lock.unlock()
        if becameEmpty { handler?() }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    var isEmpty: Bool { count == 0 }

    func snapshot() -> [FormalWrite] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.label < $1.label }
    }

    /// 按种类计数，退出提示用
    func count(of kind: FormalWrite.Kind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter { $0.kind == kind }.count
    }

    func summary() -> FormalWriteSummary {
        lock.lock(); defer { lock.unlock() }
        var result = FormalWriteSummary()
        for write in entries.values {
            switch write.kind {
            case .inPlaceEdit: result.inPlaceEdits += 1
            case .finderService: result.finderServices += 1
            case .batchExtract: result.batchExtracts += 1
            case .batchVerify: result.batchVerifications += 1
            }
        }
        return result
    }

    /// 测试用：不留下跨用例的登记与准入状态
    func reset() {
        lock.withLock {
            entries.removeAll()
            batchCancellations.removeAll()
            gate = .idle
        }
    }
}
