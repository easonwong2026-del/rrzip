// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  PendingExtraction.swift
//  rrzip
//
//  访达右键想做、但因为加密包没做完的动作。
//
//  扩展既发不出用户通知，也弹不了窗，只能把「我本来要干什么」写下来，
//  主程序解锁后接着干。没有这份记录，用户输完密码得到的是一个打开的空壳，
//  原本点的「解压到此处」就白点了。
//

import Foundation

struct PendingExtraction: Codable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// 解到压缩包所在目录
        case here
        /// 解到「包名」文件夹
        case newFolder
    }

    let id: String
    let archives: [String]
    let mode: Mode
    let createdAt: Date

    /// 超过这个时间就当作过期：用户可能只是顺手打开了同名的另一个包
    static let validInterval: TimeInterval = 120

    static var fileURL: URL {
        SharedPaths.support.appendingPathComponent("pending-extraction.json")
    }

    static func write(archives: [URL], mode: Mode) {
        let action = PendingExtraction(id: UUID().uuidString,
                                       archives: archives.map(\.path),
                                       mode: mode,
                                       createdAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(action) else { return }
        try? FileManager.default.createDirectory(at: SharedPaths.support,
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func read() -> PendingExtraction? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingExtraction.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
