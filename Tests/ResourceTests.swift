// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  资源层：缩略图缓存成本、预览解压去重、临时副本字节预算、大文件预览策略

import CoreGraphics
import Foundation

/// 缩略图缓存按位图字节计费
func testThumbnailCacheCost() {
    print("缩略图缓存 · 成本")
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        expect(false, "位图没造出来，成本无从验证")
        return
    }

    let cost = ThumbnailStore.cost(of: image)
    expect(cost == image.bytesPerRow * image.height, "成本 = bytesPerRow × height",
           "实际 \(cost)")
    expect(cost >= 120 * 80 * 4, "成本覆盖整张位图的像素存储", "实际 \(cost)")

    // 1×1 也要给正数：cost 为 0 时 NSCache 不按字节淘汰
    if let tiny = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )?.makeImage() {
        expect(ThumbnailStore.cost(of: tiny) > 0, "最小位图的成本也不为零")
    }
}

/// 同一文件并发请求：只解压一次，所有调用者拿到同一个结果
func testPayloadConcurrentDedup() {
    print("预览解压 · 并发去重")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")

        let model = ArchiveModel()
        model.open(url: fixtures.appendingPathComponent("basic.zip"))
        guard waitUntil(15, { model.current != nil }) else {
            expect(false, "归档没打开，后续无从验证")
            return
        }
        guard let entry = model.current?.entries.first(where: { $0.path == "说明.txt" }) else {
            expect(false, "样例包里找不到 说明.txt")
            return
        }

        // 先碰一次工作目录：它第一次被访问时会清掉上次运行留下的临时文件
        _ = model.cacheSizeOnDisk()
        let scratch = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rrzip/scratch", isDirectory: true)
        let before = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.count ?? 0

        // 详情栏、缩略图、悬停预览同时要同一份文件
        var results: [URL?] = []
        let lock = NSLock()
        for _ in 0..<8 {
            model.payloadURL(for: entry) { url in
                lock.lock(); results.append(url); lock.unlock()
            }
        }
        expect(ScratchUsage.shared.isWorking, "第一份解压已登记为进行中")

        guard waitUntil(20, {
            lock.lock(); defer { lock.unlock() }
            return results.count == 8
        }) else {
            expect(false, "8 个请求没有全部结束", "只回来 \(results.count) 个")
            return
        }

        let urls = results.compactMap { $0 }
        expect(urls.count == 8, "每个调用者都拿到结果", "实际 \(urls.count) 个")
        expect(Set(urls.map(\.path)).count == 1, "8 个请求共用同一份临时副本",
               "实际 \(Set(urls.map(\.path)).count) 份")
        expect(urls.first.map { FileManager.default.fileExists(atPath: $0.path) } == true,
               "临时副本还在")

        let after = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.count ?? 0
        expect(after - before == 1, "实际解压只有一次", "新增 \(after - before) 个临时目录")
        expect(waitUntil(5, { !ScratchUsage.shared.isWorking }), "worker 归零")

        ScratchUsage.shared.reset()
    }
}

/// 解压失败：等待者全部被放走，不留永久占位
func testPayloadFailureReleasesWaiters() {
    print("预览解压 · 失败路径")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")

        let model = ArchiveModel()
        model.open(url: fixtures.appendingPathComponent("basic.zip"))
        guard waitUntil(15, { model.current != nil }) else {
            expect(false, "归档没打开，后续无从验证")
            return
        }

        // 包里没有这个条目：解压必然失败
        let ghost = ArchiveEntry(path: "不存在-\(UUID().uuidString.prefix(6)).txt",
                                 size: 12, modified: "-", mode: "-rw-r--r--")
        var results: [URL?] = []
        for _ in 0..<3 {
            model.payloadURL(for: ghost) { results.append($0) }
        }

        guard waitUntil(20, { results.count == 3 }) else {
            expect(false, "失败后等待者被挂住了", "只回来 \(results.count) 个")
            return
        }
        expect(results.allSatisfy { $0 == nil }, "失败结果一致传到所有等待者")
        expect(waitUntil(5, { !ScratchUsage.shared.isWorking }), "失败后 worker 归零")

        // 失败不能被记成「永远在解压」：下一次请求还得真的能跑起来
        var again: URL?
        model.payloadURL(for: ghost) { again = $0 }
        expect(ScratchUsage.shared.isWorking, "失败后重新请求仍会发起解压")
        _ = waitUntil(20, { again != nil })
        expect(waitUntil(5, { !ScratchUsage.shared.isWorking }), "第二次失败后 worker 仍归零")

        ScratchUsage.shared.reset()
    }
}

/// 临时副本按字节回收
func testScratchTrimBudget() {
    print("临时副本 · 字节预算")
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("rrzip-trim-\(UUID().uuidString)", isDirectory: true)
    let payload = Data(count: 1024 * 1024)
    ScratchUsage.shared.reset()

    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // 四个 1 MB 的「一次解压产物」，时间从旧到新
        var dirs: [URL] = []
        for index in 0..<4 {
            let dir = root.appendingPathComponent("copy-\(index)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try payload.write(to: dir.appendingPathComponent("file.bin"))
            let when = Date().addingTimeInterval(Double(index - 4) * 60)
            try fm.setAttributes([.modificationDate: when], ofItemAtPath: dir.path)
            dirs.append(dir)
        }

        let first = CacheMaintenance.trim(root, budget: 2 * 1024 * 1024)
        expect(first.removed == 2, "超出预算时按最久未用回收", "实际 \(first.removed) 个")
        expect(first.bytes <= 2 * 1024 * 1024, "回收后回到预算内", "剩 \(first.bytes)")
        expect(!fm.fileExists(atPath: dirs[0].path), "最旧的被删")
        expect(fm.fileExists(atPath: dirs[3].path), "最新的留着")
        expect(!first.overBudget, "回收后不再超预算")

        // 被界面占用的那份不能删，哪怕它最旧
        let playing = root.appendingPathComponent("playing", isDirectory: true)
        try fm.createDirectory(at: playing, withIntermediateDirectories: true)
        try payload.write(to: playing.appendingPathComponent("movie.mp4"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                             ofItemAtPath: playing.path)
        let heldFile = playing.appendingPathComponent("movie.mp4")
        ScratchUsage.shared.hold(heldFile)

        let second = CacheMaintenance.trim(root, budget: 1024 * 1024)
        expect(fm.fileExists(atPath: heldFile.path), "正在播放的文件不被删")
        expect(second.removed >= 1, "仍然按预算回收了别的副本", "实际 \(second.removed) 个")

        // 候选全被占用：允许超预算，如实报告
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        try fm.createDirectory(at: extra, withIntermediateDirectories: true)
        try payload.write(to: extra.appendingPathComponent("second.mp4"))
        ScratchUsage.shared.hold(extra.appendingPathComponent("second.mp4"))

        let third = CacheMaintenance.trim(root, budget: 1)
        expect(third.removed == 0, "候选都在用时不强删", "实际 \(third.removed) 个")
        expect(fm.fileExists(atPath: heldFile.path) && fm.fileExists(atPath: extra.path),
               "两份在用的一份都没少")
        expect(third.overBudget, "允许暂时超预算并如实标记")

        // keep 里的那一份同样不动（刚解出来、还没交到界面手里的）
        ScratchUsage.shared.reset()
        let fourth = CacheMaintenance.trim(root, budget: 1, keep: [playing.path])
        expect(fm.fileExists(atPath: playing.path), "keep 里的副本不被删")
        expect(fourth.removed >= 1, "其余照常回收", "实际 \(fourth.removed) 个")
    } catch {
        expect(false, "字节预算 抛出异常", "\(error)")
    }

    try? fm.removeItem(at: root)
    ScratchUsage.shared.reset()
}

/// 内嵌预览的大小判断必须发生在解压之前
func testInlinePreviewLimit() {
    print("内嵌预览 · 大小判断")
    let video = ArchiveEntry(path: "big.mp4", size: 900 * 1024 * 1024, modified: "-", mode: "-rw-r--r--")
    expect(InlinePreviewLimits.skipsExtraction(video), "超过 800 MiB 的视频不解压")

    let audio = ArchiveEntry(path: "big.flac", size: 900 * 1024 * 1024, modified: "-", mode: "-rw-r--r--")
    expect(InlinePreviewLimits.skipsExtraction(audio), "音频同一口径")

    let small = ArchiveEntry(path: "ok.mp4", size: 300 * 1024 * 1024, modified: "-", mode: "-rw-r--r--")
    expect(!InlinePreviewLimits.skipsExtraction(small), "300 MB 的视频照常预览")

    let edge = ArchiveEntry(path: "edge.mp4", size: InlinePreviewLimits.media,
                            modified: "-", mode: "-rw-r--r--")
    expect(!InlinePreviewLimits.skipsExtraction(edge), "正好 800 MiB 仍然预览")

    // 元数据没写大小：判不了，仍然解压，由调用方解压后复核
    let unknown = ArchiveEntry(path: "unknown.mp4", size: -1, modified: "-", mode: "-rw-r--r--")
    expect(!InlinePreviewLimits.skipsExtraction(unknown), "大小未知时不预先拦截")

    let image = ArchiveEntry(path: "big.png", size: 900 * 1024 * 1024, modified: "-", mode: "-rw-r--r--")
    expect(!InlinePreviewLimits.skipsExtraction(image), "图片不受音视频上限约束")
}

func runResourceTests() {
    testThumbnailCacheCost()
    testPayloadConcurrentDedup()
    testPayloadFailureReleasesWaiters()
    testScratchTrimBudget()
    testInlinePreviewLimit()
}
