// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  归档读写：解析、列表、编辑、校验

import Foundation

/// decodeEscapes
func testDecodeEscapes() {
    print("decodeEscapes")
    expect(Tar.decodeEscapes(#"\350\257\264\346\230\216.txt"#) == "说明.txt", "中文转义还原")
    expect(Tar.decodeEscapes("plain.txt") == "plain.txt", "无转义原样返回")
    expect(Tar.decodeEscapes(#"a\040b"#) == "a b", "空格转义还原")
}

/// zip 列表
func testZipListing() {
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
}

/// 目录折叠
func testDirectoryFolding() {
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
}

/// tar.gz 列表
func testTgzListing() {
    print("tar.gz 列表")
    do {
        let entries = try Tar.list(fixtures.appendingPathComponent("bundle.tgz"))
        expect(entries.contains { $0.path == "readme.txt" }, "tgz 条目")
    } catch {
        expect(false, "tgz 列表", "\(error)")
    }
}

/// 加密 7z
func testEncrypted7z() {
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
}

/// 格式识别
func testFormatDetection() {
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
}

/// 原地编辑
func testInPlaceEditing() {
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
}

/// 子项索引
func testChildIndex() {
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
}

/// 原子写入
func testAtomicWrite() {
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
}

/// 完整性校验
func testVerify() {
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
}

func runArchiveTests() {
    testDecodeEscapes()
    testZipListing()
    testDirectoryFolding()
    testTgzListing()
    testTarVerboseMetadata()
    testSevenZipListingDiagnostics()
    testSevenZipVerifyPasswordDiagnostics()
    testEncrypted7z()
    testFormatDetection()
    testInPlaceEditing()
    testChildIndex()
    testAtomicWrite()
    testVerify()
}

private func testTarVerboseMetadata() {
    print("bsdtar 列表 · 时间、locale 与文件类型")
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
    let link = Tar.parse(#"lrwxrwxrwx  0 0 0 0 Dec 31 21:48 docs/alias -> ../\350\257\264\346\230\216.txt"#, now: now)
    expect(link?.path == "docs/alias", "软链名剥离目标")
    expect(link?.symlinkTarget == "../说明.txt", "兼容非 UTF-8 locale 的八进制目标")
    expect(link?.modifiedDate.map { calendar.component(.year, from: $0) } == 2025, "年初正确解析去年最近日期")
    let regular = Tar.parse("-rwSr--r-T  0 0 0 12 Jan  5  2025 file -> name", now: now)
    expect(regular?.path == "file -> name", "普通文件名保留箭头")
    expect(regular?.mode == "-rwSr--r-T", "保留 S 与 T 权限位")
    expect(regular?.modifiedDate == calendar.date(from: DateComponents(year: 2025, month: 1, day: 5)),
           "带年份的不规则空格日期可解析")
    for mode in ["brw-rw----", "crw-rw----", "prw-r-----", "srwxrwxrwx"] {
        expect(Tar.parse("\(mode) 0 root wheel 0 Apr 25  2022 special")?.mode == mode, "支持 \(mode) 模式")
    }
    expect(Tar.parse("malformed listing") == nil, "拒绝无效列表行")

    let env = Process()
    env.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    env.arguments = ["LC_ALL=zh_CN.UTF-8", "LC_TIME=fr_FR.UTF-8",
                     Bundle.main.executableURL!.path, "--tar-locale", fixtures.path]
    do {
        try env.run()
        env.waitUntilExit()
        expect(env.terminationStatus == 0, "父进程 LC_ALL / LC_TIME 不影响英文日期或中文路径")
    } catch {
        expect(false, "运行 locale 回归测试", "\(error)")
    }
}

private func testSevenZipListingDiagnostics() {
    print("7-Zip 列表 · 密码与损坏诊断")
    guard SevenZip.isAvailable else { return }
    for ext in ["7z", "zip"] {
        let url = fixtures.appendingPathComponent("encrypted-name-broken.\(ext)")
        do {
            try Data("plain text".utf8).write(to: url)
            _ = try SevenZip.list(url)
            expect(false, "损坏 \(ext) 应报错")
        } catch ArchiveError.tool(let message) {
            expect(!message.isEmpty, "损坏 \(ext) 保留引擎诊断")
        } catch {
            expect(false, "损坏 \(ext) 被误判", "\(error)")
        }
    }
    let encrypted = fixtures.appendingPathComponent("secret.7z")
    for password in [nil, "wrong"] {
        do {
            _ = try SevenZip.list(encrypted, password: password)
            expect(false, "应识别头加密归档的缺失或错误密码")
        } catch ArchiveError.needsPassword {
            expect(true, "7-Zip 的明确密码诊断会弹出密码提示")
        } catch {
            expect(false, "7-Zip 加密诊断未识别", "\(error)")
        }
    }
    let listing = SevenZip.parseList("""
        Path = folder/link
        Size = 0
        Modified = 2025-01-05 13:24:19.312
        Mode = lrwxrwxrwx
        Symbolic Link = ../data

        Path = second-link
        Target = data
        """)
    expect(listing.first?.symlinkTarget == "../data", "读取 Symbolic Link 字段")
    expect(listing.last?.symlinkTarget == "data", "读取 Target 字段")
    let date = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2025, month: 1, day: 5, hour: 13, minute: 24, second: 19))
    expect(listing.first?.modifiedDate == date, "7-Zip 时间保留秒")
    expect(listing.last?.modifiedDate == nil, "没有时间的条目保持无日期")
}

private func testSevenZipVerifyPasswordDiagnostics() {
    print("7-Zip 校验 · 条目密码诊断与批量跳过")
    guard SevenZip.isAvailable else { return }
    let input = fixtures.appendingPathComponent("src/说明.txt")
    let zip = fixtures.appendingPathComponent("verify-locked.zip")
    let seven = fixtures.appendingPathComponent("verify-locked.7z")
    do {
        try SevenZip.create(at: zip, from: [input], format: "zip", password: "pw123", volume: nil)
        try SevenZip.run(["a", "-t7z", "-y", "-ppw123", "-mhe=off", seven.path, "--", input.path],
                         captureOutput: false)
        for url in [zip, seven] {
            for password in [nil, "incorrect"] {
                do {
                    try SevenZip.verify(url, password: password)
                    expect(false, "加密载荷校验应要求密码")
                } catch ArchiveError.needsPassword {
                    expect(true, "正确识别 \(url.pathExtension) 载荷的密码诊断")
                }
            }
            try SevenZip.verify(url, password: "pw123")
            expect(true, "正确密码通过 \(url.pathExtension) 的实际完整性校验")
        }
        MainActor.assumeIsolated {
            let batch = BatchRunner(urls: [zip, seven], mode: .verify)
            batch.start()
            expect(waitUntil(10, { !batch.running }), "校验加密归档的批次会正常收尾")
            expect(batch.jobs.allSatisfy { $0.state == .skipped }, "批量校验把两种数据加密归档标记为跳过")
        }
    } catch { expect(false, "条目级密码诊断", "\(error)") }
}
