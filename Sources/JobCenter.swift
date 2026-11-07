// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  JobCenter.swift
//  rrzip
//
//  轻量任务队列的数据类型。真正排队的是 ArchiveModel 里的 jobQueue，
//  这里只放「一个任务长什么样」和「它有几种结局」。
//
//  为什么不做成一个独立的 JobManager 类：任务的状态、进度、取消都和
//  ArchiveModel 的状态机缠在一起（isLoading、status、passwords），
//  拆出去反而要来回转发。现在只把「排队 + 状态 + 取消」收成一套接口，
//  执行逻辑仍留在各自的压缩 / 解压方法里。
//

import Foundation

/// 界面上一个正在跑的任务
struct TaskJob: Identifiable, Equatable {
    let id: UUID
    let title: String
    let detail: String
    /// nil 表示引擎给不出真实百分比（tar 就是），界面显示不确定进度
    var fraction: Double?
    /// 排在这个任务后面的数量
    var queued: Int = 0
}

/// 任务的结局。由执行体自己判断——队列不猜，只记流水。
enum JobResult: Equatable {
    case succeeded
    case failed(String)
    case cancelled
}

/// 队列里的一条，还没开始跑
struct PendingJob {
    let id: UUID
    let title: String
    let detail: String
    /// 执行体。参数是自己的任务 ID，用来把进度回调对号入座。
    let work: @MainActor (UUID) async -> JobResult
}
