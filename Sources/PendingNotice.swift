// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  PendingNotice.swift
//  rrzip
//
//  访达那边做完、但需要人知道的一句话。
//
//  背景：appex 发不出用户通知，所以「跳过 14 个同名文件」「解压失败」这类
//  需要被看见的结果，只能转交主程序显示。不转移就等于没发生。
//

import Foundation

struct PendingNotice: Codable, Sendable {
    let title: String
    let message: String
    let createdAt: Date

    /// 超过这个时间就丢掉：用户可能过了一天才打开 app，旧提示只会莫名其妙
    static let validInterval: TimeInterval = 300

    static var fileURL: URL {
        SharedPaths.support.appendingPathComponent("pending-notice.json")
    }

    static func write(title: String, message: String) {
        let notice = PendingNotice(title: title, message: message, createdAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notice) else { return }
        try? FileManager.default.createDirectory(at: SharedPaths.support,
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 读一次就清掉，同一条提示不会反复弹
    static func take() -> PendingNotice? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        try? FileManager.default.removeItem(at: fileURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notice = try? decoder.decode(PendingNotice.self, from: data),
              Date().timeIntervalSince(notice.createdAt) < validInterval else { return nil }
        return notice
    }
}
