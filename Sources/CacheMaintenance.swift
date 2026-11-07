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
    /// 有任务 / 预览正在跑，这次没动
    var blocked = false
    /// 删不掉的条目数（权限等）
    var failures = 0
    /// 正在被预览或缩略图使用的条目数，主动跳过
    var inUse = 0
    /// 读不出来的根目录数。读失败不等于目录是空的，不能当成功
    var unreadable = 0

    var succeeded: Bool { !blocked && failures == 0 && unreadable == 0 }

    var text: String {
        if blocked { return "有任务或预览正在使用临时文件，等它结束后再清理" }
        if unreadable > 0 {
            return "有 \(unreadable) 个缓存目录读不出来，清理未完成"
        }
        if failures > 0 {
            return "已清理 \(ByteFormatter.string(freedBytes))，另有 \(failures) 项未能删除"
        }
        if inUse > 0 {
            return "已清理 \(ByteFormatter.string(freedBytes))，\(inUse) 项正在使用已跳过"
        }
        if remainingBytes > 0 {
            return "已清理 \(ByteFormatter.string(freedBytes))，\(ByteFormatter.string(remainingBytes)) 仍在使用"
        }
        if freedBytes == 0 { return "没有可清理的缓存" }
        return "已清理 \(ByteFormatter.string(freedBytes))"
    }
}

/// 临时文件「正在被谁用」的登记处。
///
/// 任务队列看得见压缩与解压，但看不见另外两条路：预览解压（`payloadURL`）
/// 和缩略图渲染。它们独立跑，清理缓存时只判 `job != nil` 就会把人家正在读的
/// 文件删掉——缩略图渲染失败、空格预览变空白。
///
/// 两种登记：
/// - worker：一段正在进行的活（解压中 / 渲染中），有它就整体不清，简单安全。
/// - hold：已经交给界面的文件（快速查看面板正显示着），只跳过那一个。
final class ScratchUsage: @unchecked Sendable {
    static let shared = ScratchUsage()

    private let lock = NSLock()
    private var workers = 0
    private var holds: [String: Int] = [:]

    /// 开始一段会读写临时文件的工作。必须在派发任务之前调用，
    /// 放到 Task 里就晚了：调用方紧接着清缓存会漏判。
    func beginWork() {
        lock.lock(); workers += 1; lock.unlock()
    }

    func endWork() {
        lock.lock(); workers = max(0, workers - 1); lock.unlock()
    }

    var isWorking: Bool {
        lock.lock(); defer { lock.unlock() }
        return workers > 0
    }

    func hold(_ url: URL) { hold(url.path) }

    func hold(_ path: String) {
        let key = Self.canonical(path)
        lock.lock(); holds[key, default: 0] += 1; lock.unlock()
    }

    func release(_ url: URL) { release(url.path) }

    func release(_ path: String) {
        let key = Self.canonical(path)
        lock.lock()
        if let count = holds[key] {
            if count <= 1 { holds.removeValue(forKey: key) } else { holds[key] = count - 1 }
        }
        lock.unlock()
    }

    /// 这个路径，或它下面的任何文件是否被占着。
    /// 删的是目录时要比前缀：没人会 hold 一个目录，但会 hold 目录里的文件。
    func isHeld(_ path: String) -> Bool {
        let key = Self.canonical(path)
        lock.lock(); defer { lock.unlock() }
        if holds[key] != nil { return true }
        let prefix = key.hasSuffix("/") ? key : key + "/"
        return holds.keys.contains { $0.hasPrefix(prefix) }
    }

    /// 路径比较必须先抹平软链接：`contentsOfDirectory` 返回的是真实路径
    /// （/private/var/…），而调用方手里常是 /var/…，直接比字符串永远不相等。
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return workers == 0 && holds.isEmpty
    }

    /// 测试用：不留下跨用例的计数
    func reset() {
        lock.lock(); workers = 0; holds.removeAll(); lock.unlock()
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
    /// 清空 `roots` 下的内容，但保留目录本身。
    ///
    /// - `busy`：队列里有任务在跑时直接返回，不碰任何文件。
    ///   任务可能正从这儿读包内条目，删了就是把它手里的文件抽走。
    ///   预览解压与缩略图不走队列，这里另外查一次 `ScratchUsage`。
    /// - 正在被界面占用的文件单独跳过，不整体拒绝：清得掉的就清，剩下的照实报。
    /// - 根目录读不出来算失败，不能当成「空目录 → 没有可清理的缓存」。
    /// - 只删子项，不删根目录：根目录被删掉后，正在跑的预览会立刻失败，
    ///   而且下次写入还得重建，没必要。
    static func purge(_ roots: [URL], busy: Bool) -> CacheCleanupReport {
        var report = CacheCleanupReport()
        let before = roots.reduce(Int64(0)) { $0 + size(of: $1) }

        if busy || ScratchUsage.shared.isWorking {
            report.blocked = true
            report.remainingBytes = before
            return report
        }

        let fm = FileManager.default
        for root in roots {
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            } catch {
                // 以前这里是 try? + ?? []：读不出来当空目录，接着报「没有可清理的缓存」，
                // 用户以为清干净了，其实一个字都没删
                report.unreadable += 1
                continue
            }
            for child in children {
                if ScratchUsage.shared.isHeld(child.path) {
                    report.inUse += 1
                    continue
                }
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
