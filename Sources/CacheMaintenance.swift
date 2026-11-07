// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  CacheMaintenance.swift
//  rrzip
//
//  缓存清理的「真实结果」。
//
//  以前设置页点完清理就写死一句「已清理」，删没删掉、删了多少、
//  有没有任务正抱着临时文件在跑，界面一律不知道。这里把结果算清楚：
//  释放了多少、还剩多少、失败几项、是不是因为忙而跳过。
//

import Foundation

struct CacheCleanupReport: Equatable, Sendable {
    /// 本次真正删掉的字节数
    var freedBytes: Int64 = 0
    /// 清理后仍然占用的字节数
    var remainingBytes: Int64 = 0
    /// 有任务正在跑，这次没动
    var blocked = false
    /// 删不掉的条目数（权限、正在被占用等）
    var failures = 0

    var succeeded: Bool { !blocked && failures == 0 }

    var text: String {
        if blocked { return "有任务正在使用临时文件，等它结束后再清理" }
        if failures > 0 {
            return "已清理 \(ByteFormatter.string(freedBytes))，另有 \(failures) 项未能删除"
        }
        if remainingBytes > 0 {
            return "已清理 \(ByteFormatter.string(freedBytes))，\(ByteFormatter.string(remainingBytes)) 仍在使用"
        }
        if freedBytes == 0 { return "没有可清理的缓存" }
        return "已清理 \(ByteFormatter.string(freedBytes))"
    }
}

enum CacheMaintenance {

    /// 目录占用。读不到就当 0——设置页显示「—」比显示报错有用。
    static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// 清空 `roots` 下的内容，但保留目录本身。
    ///
    /// - `busy`：队列里有任务在跑时直接返回，不碰任何文件。
    ///   任务可能正从这儿读包内条目，删了就是把它手里的文件抽走。
    /// - 只删子项，不删根目录：根目录被删掉后，正在跑的预览会立刻失败，
    ///   而且下次写入还得重建，没必要。
    static func purge(_ roots: [URL], busy: Bool) -> CacheCleanupReport {
        var report = CacheCleanupReport()
        let before = roots.reduce(Int64(0)) { $0 + size(of: $1) }

        if busy {
            report.blocked = true
            report.remainingBytes = before
            return report
        }

        let fm = FileManager.default
        for root in roots {
            let children = (try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil)) ?? []
            for child in children {
                do {
                    try fm.removeItem(at: child)
                } catch {
                    report.failures += 1
                }
            }
        }

        report.remainingBytes = roots.reduce(Int64(0)) { $0 + size(of: $1) }
        // 有任务在往外写的时候剩余量可能比 before 还大，别给出负数
        report.freedBytes = max(0, before - report.remainingBytes)
        return report
    }
}
