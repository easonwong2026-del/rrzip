// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Foundation

@MainActor
final class PayloadCache {
    /// 预览/导出缓存：key = 归档路径 + 修改时间 + 条目路径
    private var payloadCache: [String: URL] = [:]
    /// 同一 key 正在解压：后来的调用者登记在这里，共享同一次结果
    private var payloadWaiters: [String: [(URL?) -> Void]] = [:]
    private var directory: URL?
    private var closed = false

    /// 临时副本的磁盘软预算。单个文件本身超预算时也照样解压，
    /// 只是它得等自己不再被占用、且比别的都老才会被回收。
    nonisolated static let diskBudget: Int64 = 1024 * 1024 * 1024

    // MARK: - 工作目录

    private static let scratchRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rrzip", isDirectory: true)
        let scratch = base.appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)   // 上次运行留下的临时文件全部清掉
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }()

    var scratch: URL {
        if let directory { return directory }
        let url = Self.scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        return url
    }

    func close() {
        closed = true
        payloadCache.removeAll()
        if let directory { ScratchUsage.shared.retire(directory) }
    }

    private func freshScratch(_ name: String = UUID().uuidString) -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 缓存与临时目录占用，设置页显示
    func sizeOnDisk() -> Int64 {
        CacheMaintenance.size(of: scratch)
    }

    /// 清掉缩略图、预览临时副本与解压缓存；不动任何压缩包。
    /// 队列里有任务在跑、或还有排队的任务，就直接返回「忙」——
    /// 只判 `job != nil` 会漏掉排队中的任务：清完它一开始跑，要读的副本已经没了。
    @discardableResult
    func clear(busy: Bool) -> CacheCleanupReport {
        let report = CacheMaintenance.purge([scratch], busy: busy)
        guard !report.blocked else { return report }

        payloadCache.removeAll()
        return report
    }

    /// 拖拽导出 / 预览用的临时文件（带缓存，同一份文件不重复解压）
    /// 异步版：预览面板和「另存为」都要等这份临时副本，
    /// 以前各自写一遍 withCheckedContinuation，收成一份
    func url(for entry: ArchiveEntry, in frame: ArchiveModel.Frame, password: String?,
             retaining retainedArchives: @escaping () -> [URL]) async -> URL? {
        let url: URL? = await withCheckedContinuation { continuation in
            self.url(for: entry, in: frame, password: password, retaining: retainedArchives) { result in
                // 交接期先兜住：回调返回后解压目录的登记就撤了，而等待者要等到
                // 下一轮 MainActor 才继续跑。这中间的副本既不在 active 也不在人手里。
                if let result { ScratchUsage.shared.hold(result) }
                continuation.resume(returning: result)
            }
        }
        // 调用方在同一轮次里接着用（自己 hold，或者立刻读），到这里交接可以放
        if let url { ScratchUsage.shared.release(url) }
        return url
    }

    func url(for entry: ArchiveEntry, in frame: ArchiveModel.Frame, password: String?,
             retaining retainedArchives: @escaping () -> [URL], completion: @escaping (URL?) -> Void) {
        guard !closed else { return completion(nil) }
        let key = cacheKey(entry, in: frame)
        if let cached = payloadCache[key], FileManager.default.fileExists(atPath: cached.path) {
            markUsed(cached)
            return completion(cached)
        }

        // 详情栏、缩略图、悬停预览常常同时要同一份文件。第一份还在解的时候
        // 后来的人只排队等结果，不再各自起一次 7zz / tar。
        if payloadWaiters[key] != nil {
            payloadWaiters[key]?.append(completion)
            return
        }
        payloadWaiters[key] = [completion]

        let destination = freshScratch()
        let engine = frame.engine
        // 预览解压不走任务队列，清缓存看不到它。先在这里登记，
        // 再派任务——顺序反了就没用：调用方紧接着清缓存会漏判。
        // 带目录登记：自动回收也要知道这一份还在写，别删人家的半成品。
        ScratchUsage.shared.beginWork(on: destination.path)
        Task {
            defer { ScratchUsage.shared.endWork(on: destination.path) }
            let url = try? await Task.detached { () -> URL in
                // 先验路径、再解压：这条路径同时给预览和导出用，
                // 恶意条目不该先写进暂存目录再被发现
                try ArchivePathGuard.validateRelative(entry.path)
                let file = destination.appendingPathComponent(entry.path)
                try ArchivePathGuard.validateContained(file, within: destination)
                switch engine {
                case .libarchive:
                    try Tar.extract(frame.archive, entries: [entry.path], to: destination, passphrase: password)
                case .sevenZip:
                    try SevenZip.extract(frame.archive, entries: [entry.path], to: destination, password: password)
                }
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw ArchiveError.tool("导出失败")
                }
                return file
            }.value
            if let url, !closed {
                payloadCache[key] = url
                // 磁盘软预算：按字节回收最久未用的临时副本。
                // 这一次的目录还在 beginWork 里登记着，回收跳不过去就超预算，不会删它
                trimScratch(retaining: retainedArchives())
            }
            // 失败的路径也要把等待者全部放走：留一个就永久挂着
            for waiter in payloadWaiters.removeValue(forKey: key) ?? [] {
                waiter(closed ? nil : url)
            }
        }
    }

    /// 按字节回收 `scratch`：正在被界面占用的、正在写入的、正在浏览的嵌套包都不动。
    /// 候选全被占用就允许暂时超预算，不做「反复解压再删除」这种事。
    private func trimScratch(retaining archives: [URL]) {
        let keep = Set(archives.compactMap { unit(of: $0) })
        CacheMaintenance.trim(scratch, budget: Self.diskBudget, keep: keep)
        // 回收掉的目录在索引里也得摘掉，否则字典只增不减、还会指向已删文件
        prunePayloadIndex()
    }

    /// 索引只留还真实存在的副本。每次回收顺带跑一遍，开销是一次 stat。
    private func prunePayloadIndex() {
        payloadCache = payloadCache.filter { FileManager.default.fileExists(atPath: $0.value.path) }
    }

    /// 丢掉一份不再需要的临时副本：从索引里摘掉，并标记为「优先回收」。
    ///
    /// 不在这里直接删目录：这份副本可能同一时刻已经交给了快速查看、缩略图或
    /// 另存为，它们还没来得及 hold。硬删就是抽走别人手里的文件；改成把目录
    /// 时间戳打到最早，下一次回收优先带走它。
    func discardPayload(_ url: URL) {
        payloadCache = payloadCache.filter { $0.value.path != url.path }
        guard let dir = unit(of: url) else { return }
        CacheMaintenance.touch(dir, at: .distantPast)
    }

    /// 索引里还认得的副本数（测试与诊断用）
    var cachedPayloadCount: Int { payloadCache.count }

    /// 缓存命中时刷新「最近使用时间」，回收按这个时间排序才是真的 LRU
    private func markUsed(_ url: URL) {
        guard let dir = unit(of: url) else { return }
        CacheMaintenance.touch(dir)
    }

    /// 副本所在的顶层目录：`scratch/<UUID>/任意层/文件` → `scratch/<UUID>`。
    /// 回收、丢弃、刷新时间都以它为单位——条目带子目录时只删一层会留下空壳。
    private func unit(of url: URL) -> String? {
        CacheMaintenance.unit(of: url.path, in: scratch)
    }

    private func cacheKey(_ entry: ArchiveEntry, in frame: ArchiveModel.Frame) -> String {
        ThumbnailStore.cacheKey(archivePath: frame.archive.path, size: frame.archiveSize,
                                modified: frame.archiveModified, entry: entry.path, maxPixel: 0)
    }

}

/// 内嵌预览（详情栏 / 悬停）的大小上限。
///
/// 音频、视频要整份解压到临时目录才能播，超过上限的条目一旦解压就是几百 MB
/// 的磁盘写入和 I/O，最后还是播不了。所以先按条目大小判断，再决定动不动解压。
enum InlinePreviewLimits {
    static let media: Int64 = 800 * 1024 * 1024
    static let image: Int64 = 80 * 1024 * 1024
    static let pdf: Int64 = 150 * 1024 * 1024
    static let imageMaxPixel: CGFloat = 4096
    // 部分解码器会在生成缩略图前展开源位图，单独限制原图像素数。
    static let imageMaxSourcePixels = 64_000_000
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mpg", "mpeg"]
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"]

    static func isMedia(_ ext: String) -> Bool {
        videoExts.contains(ext) || audioExts.contains(ext)
    }

    static func exceedsLimit(_ size: Int64, for ext: String) -> Bool {
        if isMedia(ext) { return size > media }
        if imageExts.contains(ext) { return size > image }
        if ext == "pdf" { return size > pdf }
        return false
    }

    /// 已知大小超过上限：不解压，也不生成临时副本。
    ///
    /// 大小未知（`size < 0`，个别归档不写这一列）时判不了，仍然解压，
    /// 由调用方拿到临时文件后按实际大小复核——宁可白解一次，也不能凭猜测
    /// 把本来能预览的文件挡在门外。
    static func skipsExtraction(_ entry: ArchiveEntry) -> Bool {
        !entry.isDirectory && exceedsLimit(entry.size, for: entry.ext)
    }
}
