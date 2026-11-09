// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  缓存：缩略图键的身份信息、清理后能否重试、清理不动正式文件。
//

import CoreGraphics
import Foundation
import ImageIO

/// 造一张真 PNG：随机字节的假图渲染必然失败，验不了「重新生成」
private func makePNG(at url: URL, side: Int = 8) -> Bool {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage(),
       let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
       ) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

/// 缓存键必须带上包的身份：同名包被替换后不能命中旧缩略图
func testThumbnailCacheKeyIdentity() {
    print("缩略图缓存 · 键")
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let base = ThumbnailStore.cacheKey(
        archivePath: "/tmp/照片.zip", size: 1_024, modified: stamp, entry: "a.jpg", maxPixel: 160
    )

    let same = ThumbnailStore.cacheKey(
        archivePath: "/tmp/照片.zip", size: 1_024, modified: stamp, entry: "a.jpg", maxPixel: 160
    )
    expect(base == same, "同一个包的同一个条目可以复用")

    let otherSize = ThumbnailStore.cacheKey(
        archivePath: "/tmp/照片.zip", size: 2_048, modified: stamp, entry: "a.jpg", maxPixel: 160
    )
    expect(base != otherSize, "内容换了（大小变）就换键")

    let otherTime = ThumbnailStore.cacheKey(
        archivePath: "/tmp/照片.zip", size: 1_024,
        modified: stamp.addingTimeInterval(0.001), entry: "a.jpg", maxPixel: 160
    )
    expect(base != otherTime, "同一秒内被替换也认得出来（毫秒精度）")

    let otherArchive = ThumbnailStore.cacheKey(
        archivePath: "/tmp/文档.zip", size: 1_024, modified: stamp, entry: "a.jpg", maxPixel: 160
    )
    expect(base != otherArchive, "不同包的同名条目不串图")

    let otherPixel = ThumbnailStore.cacheKey(
        archivePath: "/tmp/照片.zip", size: 1_024, modified: stamp, entry: "a.jpg", maxPixel: 320
    )
    expect(base != otherPixel, "尺寸档位仍然分开")

    let unknown = ThumbnailStore.cacheKey(
        archivePath: "/tmp/照片.zip", size: nil, modified: nil, entry: "a.jpg", maxPixel: 160
    )
    expect(unknown.contains("|0|0|"), "读不到属性时退化成稳定键，不崩", unknown)
}

/// 清理之后，之前失败的缩略图必须允许重新生成
func testThumbnailClearAllowsRetry() {
    print("缩略图缓存 · 清理后重试")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("rrzip-thumb-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let png = folder.appendingPathComponent("pic.png")
            guard makePNG(at: png) else {
                expect(false, "测试图片没造出来")
                return
            }
            let archive = folder.appendingPathComponent("图.zip")
            try Tar.create(at: archive, from: [png], format: "zip")

            let model = ArchiveModel()
            model.open(url: archive)
            guard waitUntil(15, { model.current != nil }),
                  let frame = model.current,
                  let entry = frame.entries.first(where: { $0.path == "pic.png" }) else {
                expect(false, "测试包没打开")
                return
            }

            let store = ThumbnailStore()
            let key = ThumbnailStore.cacheKey(
                archivePath: archive.path,
                size: frame.archiveSize,
                modified: frame.archiveModified,
                entry: entry.path,
                maxPixel: 160
            )

            // 模拟「上次渲染失败」
            store.noteFailure(key)
            var blocked = false
            store.thumbnail(for: entry, model: model, maxPixel: 160) { image in
                blocked = image == nil
            }
            expect(blocked, "失败记录命中时不再重复解压")
            expect(store.failedCount == 1, "失败记录已登记", "实际 \(store.failedCount)")

            let versionBefore = store.version
            store.clear()
            expect(store.failedCount == 0, "清理会清掉失败记录")
            expect(store.version > versionBefore, "清理后通知界面刷新")

            var image: CGImage?
            var done = false
            store.thumbnail(for: entry, model: model, maxPixel: 160) { result in
                image = result
                done = true
            }
            expect(waitUntil(20, { done }), "清理后重新发起渲染")
            expect(image != nil, "之前失败的图片可以重新生成")
            expect(store.failedCount == 0, "成功后不再记失败")

            // 清空之后再清一次：不能因为缓存空就崩或卡住
            store.clear()
            expect(store.failedCount == 0, "空缓存重复清理也不出错")
        } catch {
            expect(false, "缩略图清理 抛出异常", "\(error)")
        }

        try? fm.removeItem(at: folder)
        ScratchUsage.shared.reset()
    }
}

/// 手动清理缓存：临时副本减少，原始压缩包与正式产物一个字节都不动
func testClearCachesKeepsRealArchives() {
    print("缓存 · 清理不碰正式文件")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("rrzip-clear-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // 原始压缩包：复制样例，避免动到 fixtures
            let original = folder.appendingPathComponent("原始.zip")
            try fm.copyItem(at: fixtures.appendingPathComponent("basic.zip"), to: original)

            let model = ArchiveModel()
            model.open(url: original)
            guard waitUntil(15, { model.current != nil }),
                  let frame = model.current,
                  let entry = frame.entries.first(where: { $0.path == "照片/002.jpg" }) else {
                expect(false, "原始包没打开")
                return
            }

            // 预览一次：在 scratch 里留下一份临时副本
            var payload: URL?
            var done = false
            model.payloadURL(for: entry) { url in
                payload = url
                done = true
            }
            expect(waitUntil(20, { done && payload != nil }), "预览解压完成")
            expect(fm.fileExists(atPath: payload?.path ?? ""), "临时副本已落盘")

            // 正式产物：走真实的写盘路径，不手搓文件
            let output = folder.appendingPathComponent("新生成的.zip")
            try ArchiveModel.writeArchive(at: output, from: [original], format: .zip,
                                          password: "", volume: nil)
            expect(fm.fileExists(atPath: output.path), "新压缩包已生成")

            let before = model.cacheSizeOnDisk()
            expect(before > 0, "清理前有临时缓存", "实际 \(before)")
            // 预览解压的登记在回调之后才撤，等它归零再清，否则会被判成「忙」
            expect(waitUntil(5, { !ScratchUsage.shared.isWorking }), "预览写入已收尾")

            let report = model.clearCaches()
            expect(!report.blocked, "没有任务时允许清理")
            expect(report.freedBytes > 0, "确实释放了空间", "实际 \(report.freedBytes)")
            expect(model.cacheSizeOnDisk() < before, "磁盘缓存实际减少")

            expect(fm.fileExists(atPath: original.path), "原始压缩包还在")
            expect(fm.fileExists(atPath: output.path), "正式生成的压缩包还在")
            expect((try? Tar.list(output).count) == 1, "生成的包内容完整")
            expect(!fm.fileExists(atPath: payload?.path ?? "x"), "临时副本已清掉")
        } catch {
            expect(false, "清理缓存 抛出异常", "\(error)")
        }

        try? fm.removeItem(at: folder)
        ScratchUsage.shared.reset()
    }
}

/// 有任务在跑时手动清理必须整体拒绝——排队中的也算「有任务」
func testClearCachesBlockedWhileBusy() {
    print("缓存 · 忙碌时拒绝清理")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        let model = ArchiveModel()
        var release: (() -> Void)?
        model.submitJob(title: "正在压缩", detail: "busy.zip") { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                release = { continuation.resume() }
            }
            return .succeeded
        }
        expect(waitUntil(5, { release != nil }), "任务已开始")

        let report = model.clearCaches()
        expect(report.blocked, "任务在跑时清理被拒绝")
        expect(report.freedBytes == 0, "一个字节都没删")
        expect(report.text.contains("任务"), "如实说明原因", report.text)

        release?()
        expect(waitUntil(5, { model.pendingJobCount == 0 }), "任务结束")
        let after = model.clearCaches()
        expect(!after.blocked, "任务结束后可以清理")
    }
}

/// 真实文件流程：打开包 → 预览图片 → 生成新包 → 关窗 → 重启 → 清理缓存。
/// 每一步都断言「两个正式压缩包还在、内容完整」，这是本次最不能破的红线。
func testRealFileFlowAcrossRelaunch() {
    print("文件保留 · 真实流程")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("rrzip-flow-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = folder.appendingPathComponent("原始.zip")
            try fm.copyItem(at: fixtures.appendingPathComponent("basic.zip"), to: original)

            // 1. 打开原始 ZIP，预览其中一张图片
            let first = ArchiveModel()
            first.open(url: original)
            guard waitUntil(15, { first.current != nil }),
                  let image = first.current?.entries.first(where: { $0.path == "照片/002.jpg" }) else {
                expect(false, "原始包没打开")
                return
            }
            var preview: URL?
            var previewDone = false
            first.payloadURL(for: image) { url in
                preview = url
                previewDone = true
            }
            expect(waitUntil(20, { previewDone && preview != nil }), "预览临时副本已生成")
            expect(fm.fileExists(atPath: preview?.path ?? ""), "预览文件可读")

            // 2. 生成一个新的 ZIP（正式产物，落在用户目录而不是缓存目录）
            let produced = folder.appendingPathComponent("新生成.zip")
            try ArchiveModel.writeArchive(at: produced, from: [original], format: .zip,
                                          password: "", volume: nil)

            // 3. 关闭窗口：什么都不做，任务不中断、缓存不清理、文件不动
            expect(fm.fileExists(atPath: original.path), "关窗后原始 ZIP 还在")
            expect(fm.fileExists(atPath: produced.path), "关窗后新生成 ZIP 还在")

            // 4. 重新启动：新的 model 第一次碰工作目录时清掉上次的临时文件
            let second = ArchiveModel()
            _ = second.cacheSizeOnDisk()
            expect(!fm.fileExists(atPath: preview?.path ?? "x"), "重启后上次的预览缓存被清掉")
            expect(fm.fileExists(atPath: original.path), "重启后原始 ZIP 还在")
            expect(fm.fileExists(atPath: produced.path), "重启后新生成 ZIP 还在")

            // 5. 重启后再打开新包，预览可以重新生成
            second.open(url: produced)
            guard waitUntil(15, { second.current != nil }),
                  let inner = second.current?.entries.first(where: { $0.path == "原始.zip" }) else {
                expect(false, "新生成的包打不开")
                return
            }
            var again: URL?
            var againDone = false
            second.payloadURL(for: inner) { url in
                again = url
                againDone = true
            }
            expect(waitUntil(20, { againDone && again != nil }), "重启后预览可以重新生成")
            if let again {
                let innerCount = (try? Tar.list(again))?.count
                let originalCount = (try? Tar.list(original))?.count
                expect(innerCount != nil && innerCount == originalCount,
                       "重新解出来的副本与原始包条目一致",
                       "临时 \(innerCount.map(String.init) ?? "—") / 原始 \(originalCount.map(String.init) ?? "—")")
            }
            expect(waitUntil(5, { !ScratchUsage.shared.isWorking }), "预览写入已收尾")

            // 6. 手动清理缓存：临时副本没了，两个正式包还在
            let report = second.clearCaches()
            expect(!report.blocked, "没有任务时可以清理")
            expect(!fm.fileExists(atPath: again?.path ?? "x"), "清理后临时副本被删")
            expect(fm.fileExists(atPath: original.path), "清理后原始 ZIP 还在")
            expect(fm.fileExists(atPath: produced.path), "清理后新生成 ZIP 还在")
            expect((try? Tar.list(produced))?.count == 1, "新生成 ZIP 内容完整")
        } catch {
            expect(false, "真实文件流程 抛出异常", "\(error)")
        }

        try? fm.removeItem(at: folder)
        ScratchUsage.shared.reset()
    }
}

/// 进子目录后仍要带着归档身份：否则缩略图缓存键会退回「只有路径」，换包就串图
func testSubdirectoryFramesKeepArchiveIdentity() {
    print("缩略图缓存 · 子目录帧")
    MainActor.assumeIsolated {
        ScratchUsage.shared.reset()
        let model = ArchiveModel()
        model.open(url: fixtures.appendingPathComponent("basic.zip"))
        guard waitUntil(15, { model.current != nil }), let root = model.current else {
            expect(false, "样例包没打开")
            return
        }
        expect(root.archiveSize != nil, "根帧记下了归档大小")
        expect(root.archiveModified != nil, "根帧记下了归档修改时间")

        model.jump(to: "照片/")
        expect(model.current?.prefix == "照片/", "已跳到子目录")
        expect(model.current?.archiveSize == root.archiveSize,
               "跳目录后仍带着归档大小（缓存键的一部分）")
        expect(model.current?.archiveModified == root.archiveModified,
               "跳目录后仍带着归档修改时间")

        // 点进目录（pushFolder 走的是另一条构造路径）
        if let city = model.visibleEntries.first(where: { $0.name == "城市" }) {
            model.activate(city)
            expect(model.current?.prefix == "照片/城市/", "已进入下一层")
            expect(model.current?.archiveSize == root.archiveSize, "逐层进入也保留归档大小")
            expect(model.current?.archiveModified == root.archiveModified, "逐层进入也保留修改时间")
        }
    }
}

func runCacheTests() {
    testThumbnailCacheKeyIdentity()
    testThumbnailClearAllowsRetry()
    testClearCachesKeepsRealArchives()
    testClearCachesBlockedWhileBusy()
    testRealFileFlowAcrossRelaunch()
    testSubdirectoryFramesKeepArchiveIdentity()
}
