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
func testInlinePreviewLimit() {    print("内嵌预览 · 大小判断")
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

/// keep 传进来的是文件路径，回收候选是顶层目录：必须归一再比，不能精确相等
func testTrimKeepDeepFilePath() {
    print("临时副本 · keep 传文件路径")
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("rrzip-keep-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? fm.removeItem(at: root)
        ScratchUsage.shared.reset()
    }
    ScratchUsage.shared.reset()

    do {
        // 一次解压的产物：顶层 UUID 目录 + 深层子目录 + 文件
        let copy = root.appendingPathComponent("COPY-UUID", isDirectory: true)
        let deep = copy.appendingPathComponent("照片/城市", isDirectory: true)
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024).write(to: deep.appendingPathComponent("video.mp4"))

        // 另有一份更旧的副本，本来该先被回收
        let older = root.appendingPathComponent("OLDER-UUID", isDirectory: true)
        try fm.createDirectory(at: older, withIntermediateDirectories: true)
        try Data(count: 1024 * 1024).write(to: older.appendingPathComponent("old.bin"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-900)],
                             ofItemAtPath: older.path)

        // 关键：传的是深层文件路径，不是目录
        let keepFile = deep.appendingPathComponent("video.mp4").path
        expect(CacheMaintenance.unit(of: keepFile, in: root) == copy.path,
               "文件路径归一到它所在的顶层目录",
               "实际 \(CacheMaintenance.unit(of: keepFile, in: root) ?? "nil")")
        expect(CacheMaintenance.unit(of: "/tmp/别的地方/x.txt", in: root) == nil,
               "不在 root 下的路径不参与保护")

        // 预算小于这一个副本：单独一个大副本超预算也不能删
        let report = CacheMaintenance.trim(root, budget: 1024 * 1024, keep: [keepFile])
        expect(fm.fileExists(atPath: keepFile), "刚解出的深层文件没被回收",
               "被删了")
        expect(!fm.fileExists(atPath: older.path), "更旧的副本照常回收")
        expect(report.overBudget, "单副本超预算时如实标记")
    } catch {
        expect(false, "keep 文件路径 抛出异常", "\(error)")
    }
}

/// 正在写入的目录不能被自动回收删掉；写完之后回收照常生效
func testTrimSkipsActiveDirectory() {
    print("临时副本 · 跳过正在写入")
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("rrzip-active-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? fm.removeItem(at: root)
        ScratchUsage.shared.reset()
    }
    ScratchUsage.shared.reset()

    do {
        let writing = root.appendingPathComponent("WRITING-UUID", isDirectory: true)
        try fm.createDirectory(at: writing, withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024).write(to: writing.appendingPathComponent("half.bin"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-900)],
                             ofItemAtPath: writing.path)

        // 另一个条目刚解完、正在触发回收
        let finished = root.appendingPathComponent("FINISHED-UUID", isDirectory: true)
        try fm.createDirectory(at: finished, withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024).write(to: finished.appendingPathComponent("done.bin"))

        ScratchUsage.shared.beginWork(on: writing.path)
        expect(ScratchUsage.shared.isActive(writing.path), "写入目录已登记为进行中")

        let report = CacheMaintenance.trim(root, budget: 1024 * 1024)
        expect(fm.fileExists(atPath: writing.appendingPathComponent("half.bin").path),
               "正在写入的目录没被删")
        expect(report.removed == 1, "只回收了已经写完的那一份", "实际 \(report.removed) 个")

        // 自己的活干完了，下一次回收就不能再拿它当豁免
        ScratchUsage.shared.endWork(on: writing.path)
        expect(!ScratchUsage.shared.isActive(writing.path), "结束后不再是写入中")
        let after = CacheMaintenance.trim(root, budget: 1)
        expect(!fm.fileExists(atPath: writing.path), "写完的副本之后照常回收")
        expect(after.removed >= 1, "回收确实发生了", "实际 \(after.removed) 个")
    } catch {
        expect(false, "跳过写入中 抛出异常", "\(error)")
    }
}

/// 两个条目同时解压：一份完成触发回收，另一份还在写，两份都要完整可用
func testConcurrentPayloadsStayIntact() {
    print("预览解压 · 两条并行互不干扰")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")

        let model = ArchiveModel()
        model.open(url: fixtures.appendingPathComponent("basic.zip"))
        guard waitUntil(15, { model.current != nil }) else {
            expect(false, "归档没打开，后续无从验证")
            return
        }
        let entries = ["说明.txt", "带 空格.txt"].compactMap { path in
            model.current?.entries.first { $0.path == path }
        }
        guard entries.count == 2 else {
            expect(false, "样例包里缺条目，无法构造交错")
            return
        }

        var results: [String: URL?] = [:]
        for entry in entries {
            model.payloadURL(for: entry) { results[entry.path] = $0 }
        }
        expect(waitUntil(30, { results.count == 2 }), "两份请求都回来了")

        for entry in entries {
            guard let url = results[entry.path] ?? nil else {
                expect(false, "\(entry.path) 没解出来")
                continue
            }
            expect(FileManager.default.fileExists(atPath: url.path), "\(entry.path) 临时副本还在")
        }
        // 两条走的是不同缓存键，必须是两份独立的副本，且都在自己的目录里
        let paths = entries.compactMap { results[$0.path]??.path }
        expect(Set(paths).count == 2, "两个条目各拿一份副本", "实际 \(Set(paths).count) 份")

        let text = results["说明.txt"]??.path ?? ""
        let content = (try? String(contentsOfFile: text, encoding: .utf8)) ?? ""
        expect(content.contains("hello"), "内容完整可读", content)

        expect(waitUntil(5, { !ScratchUsage.shared.isWorking }), "worker 归零")
        ScratchUsage.shared.reset()
    }
}

/// 丢弃超限副本：只摘索引，不硬删可能还在别人手里的共享文件
func testDiscardPayloadDefersDeletion() {
    print("临时副本 · 丢弃走延迟回收")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")

        let model = ArchiveModel()
        model.open(url: fixtures.appendingPathComponent("basic.zip"))
        guard waitUntil(15, { model.current != nil }),
              let entry = model.current?.entries.first(where: { $0.path == "说明.txt" }) else {
            expect(false, "归档没打开，后续无从验证")
            return
        }

        var first: URL?
        model.payloadURL(for: entry) { first = $0 }
        guard waitUntil(20, { first != nil }), let url = first else {
            expect(false, "第一份副本没解出来")
            return
        }
        expect(model.cachedPayloadCount >= 1, "解出的副本进了索引")

        // 模拟另一个消费者（快速查看 / 另存为）刚拿到同一个 URL，还没登记 hold
        ScratchUsage.shared.hold(url)

        model.discardPayload(url)
        expect(FileManager.default.fileExists(atPath: url.path), "共享副本不立刻硬删")
        expect(FileManager.default.fileExists(atPath: url.path), "别人手里的文件还在")

        // 索引已经摘掉：再要一次会重新解，不会把已丢弃的路径再发出去
        var second: URL?
        model.payloadURL(for: entry) { second = $0 }
        expect(waitUntil(20, { second != nil }), "重新请求能拿到新副本")
        expect(second?.path != url.path, "丢弃后不再返回旧路径",
               "旧 \(url.lastPathComponent) 新 \(second?.lastPathComponent ?? "nil")")

        ScratchUsage.shared.release(url)
        ScratchUsage.shared.reset()
    }
}

/// 登记表在后台线程上被同时改写时，计数和查询都要正确、最终归零
func testScratchUsageConcurrency() {
    print("临时登记 · 并发压力")
    let usage = ScratchUsage.shared
    usage.reset()

    let threads = 6
    let rounds = 200
    let group = DispatchGroup()
    for t in 0..<threads {
        DispatchQueue.global().async(group: group) {
            for i in 0..<rounds {
                let dir = "/tmp/rrzip-stress/\(t)/dir-\(i % 8)"
                let file = dir + "/file.bin"
                usage.hold(file)
                _ = usage.isHeld(dir)          // 目录级查询：靠前缀命中文件
                usage.beginWork(on: dir)
                _ = usage.isActive(dir)
                _ = usage.isWorking
                usage.endWork(on: dir)
                usage.release(file)
            }
        }
    }
    guard group.wait(timeout: .now() + 60) == .success else {
        expect(false, "并发登记没在 60 秒内跑完")
        return
    }

    expect(usage.isEmpty, "并发登记后 holds / active / worker 全部归零")
    expect(!usage.isWorking, "worker 计数归零")
    expect(!usage.isHeld("/tmp/rrzip-stress/0/dir-0"), "hold 没有残留")
    expect(!usage.isActive("/tmp/rrzip-stress/0/dir-0"), "active 没有残留")
    usage.reset()
}

/// 嵌套包的保护链：解压中 → 已解出未进浏览 → 已在浏览 → 离开后可回收
func testNestedArchiveProtectionChain() {
    print("嵌套包 · 保护链逐段生效")
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("rrzip-nested-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? fm.removeItem(at: root)
        ScratchUsage.shared.reset()
    }
    ScratchUsage.shared.reset()

    do {
        let copy = root.appendingPathComponent("NESTED-UUID", isDirectory: true)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        let inner = copy.appendingPathComponent("inner.zip")
        try Data(count: 2 * 1024 * 1024).write(to: inner)

        // 1) 解压阶段：目录登记为写入中，预算再小也不动
        ScratchUsage.shared.beginWork(on: copy.path)
        var report = CacheMaintenance.trim(root, budget: 1)
        expect(fm.fileExists(atPath: inner.path), "解压中不被回收")
        expect(report.removed == 0, "解压中一个都不删", "实际 \(report.removed) 个")

        // 2) 已解出、还没进 trail：enter() 挂的是文件 hold
        ScratchUsage.shared.endWork(on: copy.path)
        ScratchUsage.shared.hold(inner)
        report = CacheMaintenance.trim(root, budget: 1)
        expect(fm.fileExists(atPath: inner.path), "目录未加载完成时也不被回收")
        expect(report.overBudget, "此时如实超预算，不是偷偷删掉")
        expect(CacheMaintenance.unit(of: inner.path, in: root) == copy.path,
               "文件 hold 覆盖整个顶层目录")

        // 3) 进了 trail：hold 放掉，改由 keep 兜着
        ScratchUsage.shared.release(inner)
        report = CacheMaintenance.trim(root, budget: 1, keep: [inner.path])
        expect(fm.fileExists(atPath: inner.path), "浏览中由 trail 的 keep 兜住")

        // 4) 离开嵌套包后没有豁免，才允许回收
        report = CacheMaintenance.trim(root, budget: 1)
        expect(!fm.fileExists(atPath: inner.path), "离开后可以回收")
        expect(report.removed == 1, "回收发生了", "实际 \(report.removed) 个")
    } catch {
        expect(false, "嵌套包保护链 抛出异常", "\(error)")
    }
}

/// 真机路径：打开外层包 → 展开内层包 → 内层文件还在、占用全部释放
func testNestedArchiveBrowsing() {
    print("嵌套包 · 真实展开不留占用")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("rrzip-enter-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: work)
            ScratchUsage.shared.reset()
        }

        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let inner = work.appendingPathComponent("inner.zip")
            try fm.copyItem(at: fixtures.appendingPathComponent("basic.zip"), to: inner)
            let outer = work.appendingPathComponent("outer.zip")
            try ArchiveModel.writeArchive(at: outer, from: [inner], format: .zip, password: "", volume: nil)
            try? fm.removeItem(at: inner)

            let model = ArchiveModel()
            model.open(url: outer)
            guard waitUntil(20, { model.current != nil }) else {
                expect(false, "外层包没打开")
                return
            }
            guard let entry = model.current?.entries.first(where: { $0.path.hasSuffix("inner.zip") }) else {
                expect(false, "外层包里找不到内层包")
                return
            }

            model.enter(entry)
            guard waitUntil(30, { model.current?.archive.path.hasSuffix("inner.zip") == true }) else {
                expect(false, "内层包没能进入浏览状态")
                return
            }
            let archived = model.current!.archive
            expect(fm.fileExists(atPath: archived.path), "内层包在浏览时仍然存在")
            expect(model.isNested, "确实处在嵌套浏览状态")
            expect(model.current?.entries.contains { $0.path == "说明.txt" } == true,
                   "内层包内容可读")

            // 占用要放干净：不然这份临时副本永远回收不掉
            expect(waitUntil(5, { ScratchUsage.shared.isEmpty }), "进入浏览后占用全部释放")
        } catch {
            expect(false, "嵌套包真实展开 抛出异常", "\(error)")
        }
    }
}

/// 停在「内层包已解出、还没进浏览」这一刻：必须已经被占住
func testNestedExtractionHoldsUntilBrowsed() {
    print("嵌套包 · 解出到进浏览之间被占住")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("rrzip-window-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: work)
            ScratchUsage.shared.reset()
        }

        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let inner = work.appendingPathComponent("inner.zip")
            try fm.copyItem(at: fixtures.appendingPathComponent("basic.zip"), to: inner)
            let outer = work.appendingPathComponent("outer.zip")
            try ArchiveModel.writeArchive(at: outer, from: [inner], format: .zip, password: "", volume: nil)
            try? fm.removeItem(at: inner)

            let model = ArchiveModel()
            model.open(url: outer)
            guard waitUntil(20, { model.current != nil }),
                  let entry = model.current?.entries.first(where: { $0.path.hasSuffix("inner.zip") }) else {
                expect(false, "外层包没打开或找不到内层包")
                return
            }

            final class Box { var value: URL? }
            let box = Box()
            // 只做解压，不调用 loadFrame：正好停在被复审指出的那个空窗里
            Task { box.value = await model.extractNested(entry) }
            guard waitUntil(30, { box.value != nil }), let inside = box.value else {
                expect(false, "内层包没解出来")
                return
            }

            expect(fm.fileExists(atPath: inside.path), "内层包已落到临时目录")
            expect(ScratchUsage.shared.isHeld(inside.path),
                   "解出的这一刻已经登记占用（自动回收会跳过）")
            expect(ScratchUsage.shared.isHeld(inside.deletingLastPathComponent().path),
                   "占用覆盖整个临时目录，不是单个文件例外")

            // 收尾交给 performLoad 的 defer；测试里手动放，避免污染后续用例
            ScratchUsage.shared.release(inside)
            expect(!ScratchUsage.shared.isHeld(inside.path), "释放后不再受保护")
            expect(ScratchUsage.shared.isEmpty, "没有残留登记")
        } catch {
            expect(false, "解出空窗 抛出异常", "\(error)")
        }
    }
}

func runResourceTests() {
    testThumbnailCacheCost()
    testPayloadConcurrentDedup()
    testPayloadFailureReleasesWaiters()
    testScratchTrimBudget()
    testTrimKeepDeepFilePath()
    testTrimSkipsActiveDirectory()
    testConcurrentPayloadsStayIntact()
    testDiscardPayloadDefersDeletion()
    testScratchUsageConcurrency()
    testNestedArchiveProtectionChain()
    testNestedArchiveBrowsing()
    testNestedExtractionHoldsUntilBrowsed()
    testInlinePreviewLimit()
}
