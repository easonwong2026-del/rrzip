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
///   带目录的版本还会记下「正在往哪个目录里写」，自动回收据此跳过在写的目录。
/// - hold：已经交给界面的文件（快速查看面板正显示着），只跳过那一个。
final class ScratchUsage: @unchecked Sendable {
    static let shared = ScratchUsage()

    private let lock = NSLock()
    private var workers = 0
    private var holds: [String: Int] = [:]
    /// 正在写入的临时目录。自动回收不看清缓存那条路，必须能单独问出来
    private var active: [String: Int] = [:]

    /// 开始一段会读写临时文件的工作。必须在派发任务之前调用，
    /// 放到 Task 里就晚了：调用方紧接着清缓存会漏判。
    func beginWork() {
        lock.lock(); workers += 1; lock.unlock()
    }

    func endWork() {
        lock.lock(); workers = max(0, workers - 1); lock.unlock()
    }

    /// 带目录的版本：除了计数，还登记「正在往这个目录里写」。
    /// 只计数的话，自动回收分不清哪一次解压还没写完，会删掉别人正在写的目录。
    func beginWork(on path: String) {
        let key = Self.canonical(path)
        lock.lock(); workers += 1; active[key, default: 0] += 1; lock.unlock()
    }

    func endWork(on path: String) {
        let key = Self.canonical(path)
        lock.lock()
        workers = max(0, workers - 1)
        if let count = active[key] {
            if count <= 1 { active.removeValue(forKey: key) } else { active[key] = count - 1 }
        }
        lock.unlock()
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
        covers(holds, path)
    }

    /// 这个路径（或它下面的东西）是否有任务正在写
    func isActive(_ path: String) -> Bool {
        covers(active, path)
    }

    private func covers(_ table: [String: Int], _ path: String) -> Bool {
        let key = Self.canonical(path)
        lock.lock(); defer { lock.unlock() }
        if table[key] != nil { return true }
        let prefix = key.hasSuffix("/") ? key : key + "/"
        return table.keys.contains { $0.hasPrefix(prefix) }
    }

    /// 路径比较前先归一：
    /// - 抹平软链接（`contentsOfDirectory` 给 `/private/var/…`，调用方手里是 `/var/…`）；
    /// - 统一 Unicode 组合形式（APFS 存 NFD，Swift 字面量常是 NFC，
    ///   中文/带重音的文件名直接比会不相等，保护就静默失效了）。
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return workers == 0 && holds.isEmpty && active.isEmpty
    }

    /// 测试用：不留下跨用例的计数
    func reset() {
        lock.lock(); workers = 0; holds.removeAll(); active.removeAll(); lock.unlock()
    }
}

enum CacheMaintenance {

    /// 按字节回收临时副本的结果
    struct TrimReport: Equatable, Sendable {
        /// 本次删掉的目录数（每个目录是一次解压的产物）
        var removed = 0
        var failures = 0
        /// 回收后的剩余占用
        var bytes: Int64 = 0
        /// 候选全被占用，仍然超预算——如实留着，不强删
        var overBudget = false
    }

    /// 临时副本的字节软预算：按「目录最近使用时间」回收，直到占用回到预算以内。
    ///
    /// 以前只按条目数（300）判断，300 个小文本和 300 个视频差了几个数量级。
    ///
    /// - 保护单位是 `root` 下的直接子目录（一次解压的产物）。`keep` 里给的是
    ///   任意层级的路径，统一按 `unit(of:in:)` 归到子目录再比：调用方手里是
    ///   文件路径、这里是目录路径，精确相等会静默失配。
    /// - 正在被界面占用（`ScratchUsage.isHeld`）、正在被写入（`isActive`）的一律跳过。
    /// - 候选全在用就允许暂时超预算，返回结果里如实给出 `overBudget`。
    /// - 单个文件自己就超预算时同样不会「刚解出来就删」。
    /// - 排序依据是目录的修改时间，由调用方在缓存命中时刷新（`touch`）；
    ///   这就是「最近使用时间」，没有另建索引。
    /// - 以 `root` 下的直接子目录为回收单位：一次解压的产物连同子目录一起走，
    ///   不会留下空壳。
    @discardableResult
    static func trim(_ root: URL, budget: Int64, keep: Set<String> = []) -> TrimReport {
        var report = TrimReport()
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        // `keep` 给的是文件路径，候选是目录：先归一到同一个单位，
        // 再抹平 `/private/var` 与 `/var` 这类写法差异
        let protected = Set(keep.compactMap { unit(of: $0, in: root) })
        var total: Int64 = 0
        var candidates: [(url: URL, bytes: Int64, used: Date)] = []
        for child in children {
            let bytes = size(of: child)
            total += bytes
            if protected.contains(ScratchUsage.canonical(child.path)) { continue }
            if ScratchUsage.shared.isHeld(child.path) { continue }
            if ScratchUsage.shared.isActive(child.path) { continue }
            let used = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((child, bytes, used))
        }

        report.bytes = total
        guard total > budget else { return report }

        for item in candidates.sorted(by: { $0.used < $1.used }) {
            guard total > budget else { break }
            do {
                try fm.removeItem(at: item.url)
                total -= item.bytes
                report.removed += 1
            } catch {
                report.failures += 1
            }
        }

        report.bytes = max(0, total)
        report.overBudget = total > budget
        return report
    }

    /// 把任意层级的路径归到 `root` 下的直接子目录：`root/UUID/任意层/文件` → `root/UUID`。
    /// 不在 `root` 底下返回 nil。回收和保护都以此为单位，避免「文件路径 vs 目录路径」失配。
    static func unit(of path: String, in root: URL) -> String? {
        let rootKey = ScratchUsage.canonical(root.path)
        let key = ScratchUsage.canonical(path)
        guard key.hasPrefix(rootKey + "/") else { return nil }
        let rest = key.dropFirst(rootKey.count + 1)
        guard let first = rest.split(separator: "/").first, !first.isEmpty else { return nil }
        return rootKey + "/" + first
    }

    /// 记录一次「最近使用」：把副本所在目录的修改时间推到现在。
    /// 回收按这个时间排序，命中缓存时刷一下才是真的最近使用时间。
    static func touch(_ directory: String, at date: Date = Date()) {
        try? FileManager.default.setAttributes([.modificationDate: date],
                                               ofItemAtPath: directory)
    }

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
