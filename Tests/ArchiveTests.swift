// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  归档读写：解析、列表、编辑、校验

import Foundation

/// decodeEscapes
func testDecodeEscapes() {
    do {
        print("decodeEscapes")
        expect(Tar.decodeEscapes(#"\350\257\264\346\230\216.txt"#) == "说明.txt", "中文转义还原")
        expect(Tar.decodeEscapes("plain.txt") == "plain.txt", "无转义原样返回")
        expect(Tar.decodeEscapes(#"a\040b"#) == "a b", "空格转义还原")
    } catch {
        expect(false, "decodeEscapes 抛出异常", "\(error)")
    }
}

/// zip 列表
func testZipListing() {
    do {
        print("zip 列表")
        do {
            let entries = try Tar.list(fixtures.appendingPathComponent("basic.zip"))
            expect(entries.count == 6, "条目数 = 6", "实际 \(entries.count)")
            expect(entries.contains { $0.path == "说明.txt" }, "中文文件名")
            expect(entries.contains { $0.path == "带 空格.txt" }, "含空格文件名")
            expect(entries.contains { $0.path == "照片/" && $0.isDirectory }, "目录识别")
            expect(entries.first { $0.path == "照片/城市/001.jpg" }?.size == 200_000, "文件大小")
        } catch {
            expect(false, "zip 列表", "\(error)")
        }
    } catch {
        expect(false, "zip 列表 抛出异常", "\(error)")
    }
}

/// 目录折叠
func testDirectoryFolding() {
    do {
        print("目录折叠")
        do {
            let entries = try Tar.list(fixtures.appendingPathComponent("basic.zip"))
            let root = ArchiveModel.children(of: "", in: entries)
            expect(root.count == 3, "根层 3 项（说明.txt / 带 空格.txt / 照片/）", "实际 \(root.map(\.path))")
            expect(root.first?.isDirectory == true, "目录排在前面")

            let inner = ArchiveModel.children(of: "照片/", in: entries)
            expect(inner.count == 2, "照片/ 下 2 项", "实际 \(inner.map(\.path))")
            expect(inner.first?.path == "照片/城市/", "子目录合并成一行")

            let deep = ArchiveModel.children(of: "照片/城市/", in: entries)
            expect(deep.count == 1 && deep[0].path == "照片/城市/001.jpg", "深层只显示文件")
        } catch {
            expect(false, "目录折叠", "\(error)")
        }
    } catch {
        expect(false, "目录折叠 抛出异常", "\(error)")
    }
}

/// tar.gz 列表
func testTgzListing() {
    do {
        print("tar.gz 列表")
        do {
            let entries = try Tar.list(fixtures.appendingPathComponent("bundle.tgz"))
            expect(entries.contains { $0.path == "readme.txt" }, "tgz 条目")
        } catch {
            expect(false, "tgz 列表", "\(error)")
        }
    } catch {
        expect(false, "tar.gz 列表 抛出异常", "\(error)")
    }
}

/// 加密 7z
func testEncrypted7z() {
    do {
        print("加密 7z")
        let encrypted = fixtures.appendingPathComponent("secret.7z")
        if FileManager.default.fileExists(atPath: encrypted.path) {
            do {
                _ = try Tar.list(encrypted)
                expect(false, "无密码应报 needsPassword")
            } catch ArchiveError.needsPassword {
                expect(true, "无密码时报 needsPassword")
            } catch {
                // libarchive 可能直接失败，交给上层换引擎
                expect(true, "libarchive 拒绝（可回退 7-Zip）")
            }

            do {
                let entries = try SevenZip.list(encrypted, password: "pw123")
                expect(entries.count >= 1, "7-Zip 带密码可列出")
            } catch {
                expect(false, "7-Zip 带密码列出", "\(error)")
            }
        } else {
            print("  - 跳过（无 7zz 或样本未生成）")
        }
    } catch {
        expect(false, "加密 7z 抛出异常", "\(error)")
    }
}

/// 格式识别
func testFormatDetection() {
    do {
        print("格式识别")
        do {
            let zip = fixtures.appendingPathComponent("basic.zip")
            let byExt = FormatDetector.detect(zip)
            expect(byExt?.format.id == "zip", "zip 按后缀识别", "实际 \(byExt?.format.id ?? "nil")")
            expect(byExt?.source == .fileExtension, "后缀来源标记")

            // 改名成 .bin：后缀无效，应当靠魔数认出来
            let renamed = fixtures.appendingPathComponent("renamed.bin")
            try? FileManager.default.removeItem(at: renamed)
            try FileManager.default.copyItem(at: zip, to: renamed)
            let byMagic = FormatDetector.detect(renamed)
            expect(byMagic?.format.id == "zip", "改名后按魔数识别", "实际 \(byMagic?.format.id ?? "nil")")
            expect(byMagic?.source == .magic, "魔数来源标记")

            // 复合后缀
            let tgz = fixtures.appendingPathComponent("bundle.tgz")
            let compound = FormatDetector.detect(tgz)
            expect(compound?.compound?.id == "tar.gz", "复合后缀识别", "实际 \(compound?.compound?.id ?? "nil")")
            expect(compound?.format.id == "tar", "复合后缀回到基础格式")

            // 无后缀的 7z
            if let sevenZ = try? Data(contentsOf: fixtures.appendingPathComponent("secret.7z")) {
                let bare = fixtures.appendingPathComponent("bare_archive")
                try? sevenZ.write(to: bare)
                let detected = FormatDetector.detect(bare)
                expect(detected?.format.id == "7zip", "无后缀按魔数识别 7z", "实际 \(detected?.format.id ?? "nil")")
            }

            // 非归档文件不应误判
            let text = fixtures.appendingPathComponent("plain.txt")
            try? "just text\n".write(to: text, atomically: true, encoding: .utf8)
            expect(FormatDetector.detect(text) == nil, "普通文本不误判为归档")
        } catch {
            expect(false, "格式识别", "\(error)")
        }
    } catch {
        expect(false, "格式识别 抛出异常", "\(error)")
    }
}

/// 原地编辑
func testInPlaceEditing() {
    do {
        print("原地编辑")
        if SevenZip.isAvailable {
            do {
                let work = fixtures.appendingPathComponent("edit")
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try "one\n".write(to: work.appendingPathComponent("1.txt"), atomically: true, encoding: .utf8)
                try "two\n".write(to: work.appendingPathComponent("2.txt"), atomically: true, encoding: .utf8)
                let sub = work.appendingPathComponent("子目录")
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                try "three\n".write(to: sub.appendingPathComponent("3.txt"), atomically: true, encoding: .utf8)

                let archive = fixtures.appendingPathComponent("edit.zip")
                try? FileManager.default.removeItem(at: archive)
                try SevenZip.create(at: archive, from: [work.appendingPathComponent("1.txt")], format: "zip", password: nil, volume: nil)
                expect(try SevenZip.list(archive).count == 1, "初始 1 项")

                try SevenZip.add(archive, items: [work.appendingPathComponent("2.txt")])
                expect(try SevenZip.list(archive).count == 2, "加入根目录后 2 项")

                try SevenZip.add(archive, items: [sub.appendingPathComponent("3.txt")], prefix: "子目录/")
                let afterPrefix = try SevenZip.list(archive)
                expect(afterPrefix.contains { $0.path == "子目录/3.txt" }, "带前缀加入落到子目录",
                       "实际 \(afterPrefix.map(\.path))")

                try SevenZip.remove(archive, entries: ["1.txt"])
                let afterRemove = try SevenZip.list(archive)
                expect(afterRemove.count == 2, "删除后 2 项", "实际 \(afterRemove.count)")
                expect(!afterRemove.contains { $0.path == "1.txt" }, "被删条目已消失")
            } catch {
                expect(false, "原地编辑", "\(error)")
            }
        } else {
            print("  - 跳过（未找到 7zz）")
        }
    } catch {
        expect(false, "原地编辑 抛出异常", "\(error)")
    }
}

/// 子项索引
func testChildIndex() {
    do {
        print("子项索引")
        do {
            let entries = try Tar.list(fixtures.appendingPathComponent("basic.zip"))
            let index = ArchiveModel.buildChildIndex(entries)
            for prefix in ["", "照片/", "照片/城市/"] {
                let legacy = ArchiveModel.children(of: prefix, in: entries).map(\.path)
                let indexed = (index[prefix] ?? []).map(\.path)
                expect(legacy == indexed, "前缀「\(prefix)」与旧实现一致", "旧=\(legacy) 新=\(indexed)")
            }

            // 10 万条目：建一次索引应在秒级以内，之后取层是 O(1)
            var big: [ArchiveEntry] = []
            big.reserveCapacity(100_000)
            for i in 0..<100_000 {
                big.append(ArchiveEntry(path: "dir\(i % 200)/sub\(i % 50)/file\(i).txt",
                                        size: 1, modified: "2026-11-05 10:00", mode: "-rw-r--r--"))
            }
            let started = Date()
            let bigIndex = ArchiveModel.buildChildIndex(big)
            let elapsed = Date().timeIntervalSince(started)
            expect(bigIndex.count > 300, "10 万条目建出多级目录", "实际 \(bigIndex.count) 层")
            expect(elapsed < 10.0, "10 万条目建索引 < 10s（CI runner 偏慢，留足余量）", "实际 \(String(format: "%.3f", elapsed))s")

            let started2 = Date()
            _ = bigIndex["dir7/sub7/"]
            expect(Date().timeIntervalSince(started2) < 0.05, "取一层是常数时间")
        } catch {
            expect(false, "子项索引", "\(error)")
        }
    } catch {
        expect(false, "子项索引 抛出异常", "\(error)")
    }
}

/// 原子写入
func testAtomicWrite() {
    do {
        print("原子写入")
        do {
            let out = fixtures.appendingPathComponent("atomic.zip")
            try? FileManager.default.removeItem(at: out)
            try "OLD".write(to: out, atomically: true, encoding: .utf8)

            let src = fixtures.appendingPathComponent("atomic-src.txt")
            try "NEW".write(to: src, atomically: true, encoding: .utf8)

            try ArchiveModel.writeArchive(at: out, from: [src], format: .zip, password: "", volume: nil)
            let afterSuccess = try Tar.list(out)
            expect(afterSuccess.contains { $0.name == "atomic-src.txt" }, "成功后目标被新内容替换")

            // 用一个不存在的输入制造失败：原来的包必须原样还在
            let before = try Data(contentsOf: out)
            let missing = fixtures.appendingPathComponent("missing-\(UUID().uuidString).txt")
            do {
                try ArchiveModel.writeArchive(at: out, from: [missing], format: .zip, password: "", volume: nil)
                expect(false, "缺失输入时应当报错")
            } catch {
                let after = try Data(contentsOf: out)
                expect(before == after, "创建失败后原包逐字节未变")

                let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fixtures.path))?
                    .filter { $0.hasPrefix(".atomic-") } ?? []
                expect(leftovers.isEmpty, "失败后不残留临时文件", "实际 \(leftovers)")
            }
        } catch {
            expect(false, "原子写入", "\(error)")
        }
    } catch {
        expect(false, "原子写入 抛出异常", "\(error)")
    }
}

/// 完整性校验
func testVerify() {
    do {
        print("完整性校验")
        if SevenZip.isAvailable {
            do {
                let good = fixtures.appendingPathComponent("basic.zip")
                do { try SevenZip.verify(good); expect(true, "正常包校验通过") }
                catch { expect(false, "正常包校验通过", "\(error)") }

                // 截掉一半字节，模拟下载不完整
                let broken = fixtures.appendingPathComponent("broken.zip")
                let data = try Data(contentsOf: good)
                try data.prefix(data.count / 2).write(to: broken)
                var failed = false
                do { try SevenZip.verify(broken) } catch { failed = true }
                expect(failed, "截断的包校验失败")
            } catch {
                expect(false, "完整性校验", "\(error)")
            }
        } else {
            print("  - 跳过（未找到 7zz）")
        }
    } catch {
        expect(false, "完整性校验 抛出异常", "\(error)")
    }
}

func runArchiveTests() {
    testDecodeEscapes()
    testZipListing()
    testDirectoryFolding()
    testTgzListing()
    testEncrypted7z()
    testFormatDetection()
    testInPlaceEditing()
    testChildIndex()
    testAtomicWrite()
    testVerify()
}
