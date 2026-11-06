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

/// 进度回调
func testProgress() {
    do {
        print("进度回调")
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
    testProgress()
    testCompressPaths()
}
