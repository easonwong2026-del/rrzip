// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  FormalWriteLedger.swift
//  rrzip
//
//  不经过任务队列、但会写用户文件的活：
//  - 原地增删压缩包条目（7zz 正在改用户的原包）
//  - 访达右键服务（压缩 / 解压，产物直接落在用户目录）
//
//  它们和预览缓存有本质区别：
//  - 删掉 / 写坏目标文件是毁用户数据，不能像预览缓存那样 5 秒后一走了之；
//  - 7zz 正在改原包，也不能 terminate 它来「取消」——半截的压缩包比不退出更糟。
//  所以退出协调对它们只有一个策略：等它跑完。
//
//  登记必须**同步**发生在派发任务之前。反过来（先派发再登记）的话，
//  中间那一下 ⌘Q 就会漏判——这正是原地编辑和访达服务以前的问题。
//

import Foundation

/// 正式写入的细分。退出提示要分别说清「在改哪个包」和「在给谁压缩」。
struct FormalWriteSummary: Equatable, Sendable {
    var inPlaceEdits = 0
    var finderServices = 0

    var total: Int { inPlaceEdits + finderServices }
    var isEmpty: Bool { total == 0 }
}

/// 一项正在写入用户文件的工作
struct FormalWrite: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// 原地增删压缩包条目：改的是用户的原包
        case inPlaceEdit
        /// 访达右键服务：压缩 / 解压
        case finderService

        var title: String {
            switch self {
            case .inPlaceEdit: return "原地编辑压缩包"
            case .finderService: return "访达服务"
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
    /// 归零时回调一次（可选）。没有它也能退出，只是要多等一个轮询周期。
    private var emptyHandler: (@Sendable () -> Void)?

    /// 数量归零时回调。设置方负责切回主线程。
    func onEmpty(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); emptyHandler = handler; lock.unlock()
    }

    @discardableResult
    func begin(_ kind: FormalWrite.Kind, label: String) -> UUID {
        let write = FormalWrite(id: UUID(), kind: kind, label: label)
        lock.lock(); entries[write.id] = write; lock.unlock()
        return write.id
    }

    func end(_ id: UUID) {
        var becameEmpty = false
        var handler: (@Sendable () -> Void)?
        lock.lock()
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
            }
        }
        return result
    }

    /// 测试用：不留下跨用例的登记
    func reset() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
