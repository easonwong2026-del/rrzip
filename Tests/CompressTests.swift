// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  压缩：级别、进度、包内路径

import Foundation

/// 压缩级别
func testCompressLevel() {
    do {
        print("压缩级别")
        expect(CompressLevel.allCases.count == 4, "四档级别")
        expect(CompressLevel.store.argument == 0, "存储 = -mx=0")
        expect(CompressLevel.normal.argument == 5, "标准 = -mx=5")
        expect(CompressLevel.max.argument == 9, "极限 = -mx=9")
    } catch {
        expect(false, "压缩级别 抛出异常", "\(error)")
    }
}

/// 四档级别必须真的改变产物体积。
///
/// 之前只测了「0/1/5/9 映射到 -mx」，结果主程序压普通 ZIP 走的是 bsdtar，
/// 那一路根本不认 -mx，选「极限」和「存储」压出来一样大，测试却全绿。
/// 这里用真实产物说话。
func testCompressLevelEffect() {
    do {
        print("压缩级别真的生效")
        guard SevenZip.isAvailable else {
            print("  - 跳过：7zz 不可用")
            return
        }

        let dir = fixtures.appendingPathComponent("level-src", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 可压缩内容：2 MB 重复文本，store 与 max 的体积差会非常明显
        let text = String(repeating: "rrzip compress level check 0123456789\n", count: 60_000)
        try text.write(to: dir.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        func makeZip(_ level: CompressLevel, name: String) throws -> URL {
            let out = fixtures.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: out)
            try SevenZip.create(at: out, from: [dir], format: "zip",
                                password: nil, volume: nil, level: level.argument)
            return out
        }

        func size(_ url: URL) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }

        let store = try makeZip(.store, name: "level-store.zip")
        let fast = try makeZip(.fast, name: "level-fast.zip")
        let normal = try makeZip(.normal, name: "level-normal.zip")
        let maxed = try makeZip(.max, name: "level-max.zip")

        // 四档都得验。只比 store 和 max 的话，中间两档即使被忽略也看不出来。
        expect(size(store) >= size(fast), "快速档不大于存储档",
               "store=\(size(store)) fast=\(size(fast))")
        expect(size(fast) >= size(normal), "标准档不大于快速档",
               "fast=\(size(fast)) normal=\(size(normal))")
        expect(size(normal) >= size(maxed), "极限档不大于标准档",
               "normal=\(size(normal)) max=\(size(maxed))")
        expect(size(store) > size(maxed) * 3,
               "存储档远大于极限档", "store=\(size(store)) max=\(size(maxed))")

        // 包内路径不能因为换引擎又变成绝对路径
        let paths = (try? Tar.list(maxed).map(\.path)) ?? []
        expect(!paths.isEmpty, "7zz 压的 zip 能列出来")
        expect(paths.allSatisfy { !$0.hasPrefix("Users/") && !$0.contains("var/folders") },
               "ZIP 走 7zz 也不带绝对路径", paths.prefix(2).joined(separator: ","))

        // 端到端：主程序的 ZIP 也必须接级别（旧实现走 bsdtar，级别是摆设）
        let viaArchive = fixtures.appendingPathComponent("level-app.zip")
        try? FileManager.default.removeItem(at: viaArchive)
        try ArchiveModel.writeArchive(at: viaArchive, from: [dir], format: .zip,
                                      password: "", volume: nil, level: CompressLevel.max.argument)
        expect(size(viaArchive) < size(store),
               "主程序压 ZIP 时级别生效", "app=\(size(viaArchive)) store=\(size(store))")
    } catch {
        expect(false, "压缩级别真的生效 抛出异常", "\(error)")
    }
}

/// 跨目录同名：7-Zip 会报 errno=2，提前换成能照着做的提示
func testDuplicateNames() {
    do {
        print("跨目录同名")
        guard SevenZip.isAvailable else {
            print("  - 跳过：7zz 不可用")
            return
        }
        let a = fixtures.appendingPathComponent("dup-a", isDirectory: true)
        let b = fixtures.appendingPathComponent("dup-b", isDirectory: true)
        for dir in [a, b] {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "x".write(to: dir.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        }
        let out = fixtures.appendingPathComponent("dup.7z")
        try? FileManager.default.removeItem(at: out)

        var message = ""
        do {
            try SevenZip.create(at: out, from: [a.appendingPathComponent("same.txt"),
                                               b.appendingPathComponent("same.txt")],
                                format: "7z", password: nil, volume: nil)
            expect(false, "同名应被拦下")
        } catch {
            message = error.localizedDescription
        }
        expect(message.contains("same.txt"), "提示里带文件名", message)
        expect(message.contains("分开压缩"), "提示里给出做法", message)
        expect(!FileManager.default.fileExists(atPath: out.path), "失败不留半个包")
    } catch {
        expect(false, "跨目录同名 抛出异常", "\(error)")
    }
}

/// 分卷替换：失败要能回滚，且不能误删同前缀的其它文件
func testVolumeCommit() {
    do {
        print("分卷替换")
        let dir = fixtures.appendingPathComponent("vol-test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let output = dir.appendingPathComponent("data.zip")
        let old1 = dir.appendingPathComponent("data.zip.001")
        let old2 = dir.appendingPathComponent("data.zip.002")
        /// 同前缀但不是分卷：老实现用 hasPrefix 会把它一起删掉
        let unrelated = dir.appendingPathComponent("data.zip.bak")

        try "OLD1".write(to: old1, atomically: true, encoding: .utf8)
        try "OLD2".write(to: old2, atomically: true, encoding: .utf8)
        try "BACKUP".write(to: unrelated, atomically: true, encoding: .utf8)

        // 1) 新分卷缺失：必须回滚，旧包一个字节都不能少
        let missing = dir.appendingPathComponent(".data-xxxx.zip")
        var threw = false
        do {
            try ArchiveModel.commitStaged(missing, to: output, hasVolumes: true)
        } catch {
            threw = true
        }
        expect(threw, "产物缺失时报错，不当成功")
        expect(FileManager.default.fileExists(atPath: old1.path), "旧分卷 .001 还在")
        expect(FileManager.default.fileExists(atPath: old2.path), "旧分卷 .002 还在")
        expect(FileManager.default.fileExists(atPath: unrelated.path), "同前缀的 .bak 没被误删")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.contains(".rrzip-old-") }
        expect(leftovers.isEmpty, "没有留下备份文件", leftovers.joined(separator: ","))

        // 2) 正常替换：新分卷就位、多余旧卷清掉、无关文件仍在
        let staged = dir.appendingPathComponent(".data-yyyy.zip")
        try "NEW1".write(to: dir.appendingPathComponent(".data-yyyy.zip.001"),
                         atomically: true, encoding: .utf8)
        try ArchiveModel.commitStaged(staged, to: output, hasVolumes: true)
        let content = (try? String(contentsOf: old1, encoding: .utf8)) ?? ""
        expect(content == "NEW1", "新分卷已就位", content)
        expect(!FileManager.default.fileExists(atPath: old2.path), "旧的多余分卷被清掉")
        expect(FileManager.default.fileExists(atPath: unrelated.path), "替换后 .bak 仍在")
        let after = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.contains(".rrzip-old-") }
        expect(after.isEmpty, "替换后没有备份残留", after.joined(separator: ","))
    } catch {
        expect(false, "分卷替换 抛出异常", "\(error)")
    }
}

/// 进度回调
func testProgress() {
    do {
        print("进度回调")
        // 7zz 是构建时下载的，CI 上缺了就跳过——环境缺失不该判成功能失败
        guard SevenZip.isAvailable else {
            print("  - 跳过：7zz 不可用")
            return
        }
        do {
            let dir = fixtures.appendingPathComponent("progress-src", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let blob = Data(count: 8 * 1024 * 1024)
            try blob.write(to: dir.appendingPathComponent("big.bin"))

            let out = fixtures.appendingPathComponent("progress.7z")
            try? FileManager.default.removeItem(at: out)

            final class Box: @unchecked Sendable { var values: [Double] = [] }
            let box = Box()
            try SevenZip.create(at: out, from: [dir], format: "7z", password: nil,
                                volume: nil, level: 9, onProgress: { box.values.append($0) })
            expect(!box.values.isEmpty, "收到进度回调", "\(box.values.count) 次")
            expect(box.values.allSatisfy { $0 >= 0 && $0 <= 1 }, "进度在 0–1 之间",
                   "\(box.values.min() ?? -1)…\(box.values.max() ?? -1)")
            // 8 MB 零填充压得太快，7zz 可能只来得及刷一个 0%，不追最后值
        } catch {
            expect(false, "进度回调", "\(error)")
        }
    } catch {
        expect(false, "进度回调 抛出异常", "\(error)")
    }
}

/// 压缩路径
func testCompressPaths() {
    do {
        print("压缩路径")
        do {
            let src = fixtures.appendingPathComponent("zip-src", isDirectory: true)
            try? FileManager.default.removeItem(at: src)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let inner = src.appendingPathComponent("子目录", isDirectory: true)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try "x".write(to: inner.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

            // 单源走 ditto（扩展里压 zip 的路径）
            let single = fixtures.appendingPathComponent("zip-single.zip")
            try? FileManager.default.removeItem(at: single)
            try Tar.createZip(at: single, from: src)
            let singlePaths = try Tar.list(single).map(\.path)
            expect(singlePaths.contains { $0.hasPrefix("zip-src/") },
                   "包内以源目录名开头", singlePaths.prefix(2).joined(separator: ","))
            expect(!singlePaths.contains { $0.contains("var/folders") || $0.hasPrefix("Users/") },
                   "包内没有绝对路径前缀", singlePaths.prefix(2).joined(separator: ","))

            // 多源走 tar（同一目录下的合并压缩；跨目录会退回绝对路径，属少数情况）
            let multi = fixtures.appendingPathComponent("zip-multi.zip")
            try? FileManager.default.removeItem(at: multi)
            try Tar.create(at: multi, from: [src, single], format: "zip")
            let multiPaths = try Tar.list(multi).map(\.path)
            expect(multiPaths.contains { $0.hasPrefix("zip-src/") }, "多源保留目录名")
            expect(!multiPaths.contains { $0.contains("var/folders") || $0.hasPrefix("Users/") },
                   "多源也不带绝对路径", multiPaths.prefix(2).joined(separator: ","))
        } catch {
            expect(false, "压缩路径", "\(error)")
        }
    } catch {
        expect(false, "压缩路径 抛出异常", "\(error)")
    }
}

func runCompressTests() {
    testCompressLevel()
    testCompressLevelEffect()
    testDuplicateNames()
    testVolumeCommit()
    testProgress()
    testCompressPaths()
}
