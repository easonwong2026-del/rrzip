// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  设置相关：服务入口解压安全、访达设置落盘、解压目录解析、工作模式接线。
//  这几项都是「界面看着正常、其实不生效」的高危区，一律用真实文件跑。

import Foundation

/// 系统「服务」入口：用 rrzip 解压到此处时不能覆盖同名文件
func testServiceExtraction() {
    do {
        print("服务入口解压")
        do {
            let zip = fixtures.appendingPathComponent("basic.zip")
            let work = fixtures.appendingPathComponent("service-test", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let localZip = work.appendingPathComponent("basic.zip")
            try FileManager.default.copyItem(at: zip, to: localZip)

            // 落点 = 包所在目录，冲突策略 = 跳过（不是 ArchiveService 的默认覆盖）
            let plan = ServiceExtraction.plan(for: localZip)
            expect(plan.destination == work, "服务解压落在包所在目录")
            expect(plan.onConflict == .skip, "服务解压不覆盖已有文件")

            // 先放一个会被撞名的文件，内容必须原样保留
            let target = work.appendingPathComponent("说明.txt")
            try "ADMIN".write(to: target, atomically: true, encoding: .utf8)

            try ServiceExtraction.extract(localZip)
            let content = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            expect(content == "ADMIN", "已存在的同名文件内容不变", content)
            expect(FileManager.default.fileExists(
                atPath: work.appendingPathComponent("照片/城市/001.jpg").path),
                   "其余文件照常解出")
            expect(FileManager.default.fileExists(
                atPath: work.appendingPathComponent("带 空格.txt").path),
                   "带空格的文件名也解出来了")

            // 主程序主动解压的语义不能被这次修复带偏：默认仍是覆盖
            let overwriteDir = fixtures.appendingPathComponent("service-overwrite", isDirectory: true)
            try? FileManager.default.removeItem(at: overwriteDir)
            try FileManager.default.createDirectory(at: overwriteDir, withIntermediateDirectories: true)
            let overwriteTarget = overwriteDir.appendingPathComponent("说明.txt")
            try "ADMIN".write(to: overwriteTarget, atomically: true, encoding: .utf8)
            try ArchiveService.extract(zip, entries: [], to: overwriteDir, password: nil)
            let overwritten = (try? String(contentsOf: overwriteTarget, encoding: .utf8)) ?? ""
            expect(overwritten != "ADMIN", "主程序主动解压仍按原语义覆盖", overwritten)
        }
    } catch {
        expect(false, "服务入口解压 抛出异常", "\(error)")
    }
}

/// 访达设置落盘：首次写、覆盖写、失败保留旧值、不出现半截 JSON
func testFinderSettingsStore() {
    do {
        print("访达设置落盘")
        let dir = fixtures.appendingPathComponent("finder-store", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let fm = FileManager.default
        let file = dir.appendingPathComponent("finder.json")

        // 1. 首次保存：目录和目标文件都不存在
        var first = FinderSettings()
        first.secondLevel = false
        first.enabled = ["open", "extractHere"]
        expect(FinderSettingsStore.save(first, to: file), "首次保存返回成功")
        expect(fm.fileExists(atPath: file.path), "首次保存真的创建了文件")
        expect(FinderSettings.load(from: file) == first, "首次保存的内容能读回")

        // 2. 后续保存：目标已存在，必须整体替换
        var second = first
        second.secondLevel = true
        second.enabled = ["compressZip"]
        second.extractStrategy = .here
        expect(FinderSettingsStore.save(second, to: file), "覆盖保存返回成功")
        let reloaded = FinderSettings.load(from: file)
        expect(reloaded == second, "覆盖保存后读到的是新配置")
        expect(reloaded.extractStrategy == .here, "旧字段 extractStrategy 仍能存读")

        // 3. 不留临时文件，也不留半截 JSON
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(names == ["finder.json"], "目录里只剩 finder.json", "\(names.sorted())")
        let raw = (try? Data(contentsOf: file)) ?? Data()
        expect((try? JSONDecoder().decode(FinderSettings.self, from: raw)) != nil, "文件是完整 JSON")

        // 4. 写入失败：旧配置必须原样保留，且函数要如实返回失败
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        var third = second
        third.enabled = ["open"]
        let saved = FinderSettingsStore.save(third, to: file)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        expect(!saved, "目录不可写时如实返回失败")
        expect(FinderSettings.load(from: file) == second, "写入失败后旧配置没有被破坏")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != "finder.json" }
        expect(leftovers.isEmpty, "失败没留下临时文件", "\(leftovers.sorted())")

        // 5. 文件被写坏（旧版本残留、外部截断）时退回默认值，不能让设置页崩
        try Data("{".utf8).write(to: file)
        expect(FinderSettings.load(from: file) == FinderSettings(), "坏文件退回默认配置")

        // 6. 主程序写、扩展读：同一份字节解出来一致（扩展就是这么读的）
        let writer = FinderSettings(secondLevel: false, enabled: ["open"], extractStrategy: .newFolder)
        _ = FinderSettingsStore.save(writer, to: file)
        let extensionSide = (try? JSONDecoder().decode(
            FinderSettings.self, from: Data(contentsOf: file))) ?? FinderSettings()
        expect(extensionSide == writer, "扩展侧解出来和写入的一致")

        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    } catch {
        expect(false, "访达设置落盘 抛出异常", "\(error)")
    }
}

/// 解压位置设置的真实解析
func testExtractDestinationSetting() {
    do {
        print("解压位置设置")
        let fm = FileManager.default
        let root = fixtures.appendingPathComponent("dest-test", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        expect(ExtractDestinationSetting.resolve("") == .ask, "空串 = 每次询问")
        expect(ExtractDestinationSetting.resolve("   ") == .ask, "只有空白也当每次询问")

        let good = root.appendingPathComponent("good", isDirectory: true)
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        expect(ExtractDestinationSetting.resolve(good.path) == .fixed(good), "可用目录解析为固定目录")

        // 目录被删：不能退化成「没设过」，要带上原因
        let gone = root.appendingPathComponent("gone", isDirectory: true)
        try fm.createDirectory(at: gone, withIntermediateDirectories: true)
        try fm.removeItem(at: gone)
        let missing = ExtractDestinationSetting.resolve(gone.path)
        expect(missing == .invalid(path: gone.path, failure: .missing), "目录被删后判为 missing")
        expect(missing.problem?.isEmpty == false, "失效时有可展示的说明")

        // 路径被同名文件占了
        let asFile = root.appendingPathComponent("not-a-dir")
        try "x".write(to: asFile, atomically: true, encoding: .utf8)
        expect(ExtractDestinationSetting.resolve(asFile.path)
                == .invalid(path: asFile.path, failure: .notDirectory),
               "同名文件判为 notDirectory")

        // 权限被收回
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        expect(ExtractDestinationSetting.resolve(locked.path)
                == .invalid(path: locked.path, failure: .denied),
               "没有写权限判为 denied")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        // 探测可注入：不依赖真实权限也能覆盖 denied 分支
        let fake = ExtractDestinationSetting.Probe(isDirectory: { _ in true },
                                                   isWritable: { _ in false })
        expect(ExtractDestinationSetting.resolve("/whatever", probe: fake)
                == .invalid(path: "/whatever", failure: .denied),
               "探测结果可注入")

        // 写入侧只做裁剪，不替用户改路径
        expect(ExtractDestinationSetting.store(nil) == "", "清除等于空串")
        expect(ExtractDestinationSetting.store("  /tmp/x  ") == "/tmp/x", "写入时去掉首尾空白")
    } catch {
        expect(false, "解压位置设置 抛出异常", "\(error)")
    }
}

/// 设置页切换工作模式 = 手动切换，冷却期必须生效
func testWorkspaceModeFromSettings() {
    do {
        print("设置页切工作模式")
        MainActor.assumeIsolated {
            UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")
            let model = ArchiveModel()
            let collapse = Layout.autoCollapseWidth

            // 先让自动模式建立一帧宽度基准
            _ = model.autoMode(forWidth: collapse - 100)
            model.selectWorkspaceModeFromSettings(.full)
            expect(model.workspaceMode == .full, "设置页切到完整模式")
            expect(UserDefaults.standard.string(forKey: "rrzip.workspaceMode") == "full",
                   "切换后立即落盘")

            // 冷却期内自动模式不许抢：这正是旧版直接绑 workspaceMode 的洞
            expect(model.autoMode(forWidth: collapse - 200) == nil,
                   "设置页切换后冷却期内不被自动模式覆盖")

            // 冷却期一过，自动模式恢复工作（方向感知照旧）
            let later = Date().addingTimeInterval(301)
            _ = model.autoMode(forWidth: collapse - 100, now: later)
            expect(model.autoMode(forWidth: collapse - 50, now: later) == .compact,
                   "冷却期过后自动收起仍然有效")

            // 切到当前已是的模式也算一次手动操作，仍然钉住
            model.setWorkspaceMode(.compact, manual: false)
            model.selectWorkspaceModeFromSettings(.compact)
            expect(model.autoMode(forWidth: collapse + 100) == nil, "选同一个模式也进入冷却期")
        }
    } catch {
        expect(false, "设置页切工作模式 抛出异常", "\(error)")
    }
}

/// 缓存清理：结果必须是真的，忙的时候不碰文件
func testCacheMaintenance() {
    do {
        print("缓存清理")
        let fm = FileManager.default
        let root = fixtures.appendingPathComponent("cache-test", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let nested = root.appendingPathComponent("scratch/预览", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 400).write(to: root.appendingPathComponent("thumb.png"))
        try Data(count: 600).write(to: nested.appendingPathComponent("payload.bin"))

        expect(CacheMaintenance.size(of: root) == 1000, "占用算的是文件字节总和",
               "\(CacheMaintenance.size(of: root))")

        // 有任务在跑：一个字节都不许动
        let blocked = CacheMaintenance.purge([root], busy: true)
        expect(blocked.blocked, "忙碌时直接拒绝清理")
        expect(blocked.freedBytes == 0, "忙碌时没有释放")
        expect(CacheMaintenance.size(of: root) == 1000, "忙碌时文件原样保留")
        expect(blocked.text.contains("任务"), "忙碌时有可展示的原因", blocked.text)

        // 正常清理：内容清空，目录本身留着
        let report = CacheMaintenance.purge([root], busy: false)
        expect(report.freedBytes == 1000, "释放量等于原占用", "\(report.freedBytes)")
        expect(report.remainingBytes == 0, "清理后剩余为 0")
        expect(report.succeeded, "无失败项")
        expect(fm.fileExists(atPath: root.path), "根目录保留")
        let left = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        expect(left.isEmpty, "子项全部清掉", "\(left)")

        // 已经空了：要说「没有可清理的缓存」，不能假装清了东西
        let empty = CacheMaintenance.purge([root], busy: false)
        expect(empty.freedBytes == 0 && empty.text.contains("没有"), "空目录如实回复", empty.text)

        // 删不掉的条目要计数，不能报成功
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 100).write(to: locked.appendingPathComponent("busy.bin"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let partial = CacheMaintenance.purge([root], busy: false)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        expect(partial.failures > 0, "删不掉的条目计入失败", "\(partial.failures)")
        expect(!partial.succeeded, "有失败项时不算成功")
        expect(partial.text.contains("未能删除"), "失败有可展示的说明", partial.text)

        try? fm.removeItem(at: root)
    } catch {
        expect(false, "缓存清理 抛出异常", "\(error)")
    }
}

/// 旧配置兼容：界面拿掉的选项，数据不能跟着丢
func testFinderConfigCompat() {
    do {
        print("访达配置兼容")
        let file = fixtures.appendingPathComponent("finder-compat.json")
        try? FileManager.default.removeItem(at: file)

        // 上一版本用户可能存着「压缩为 7Z」和 extractStrategy
        let legacy = Data(#"""
        {"secondLevel":true,"enabled":["open","compressSevenZip"],"extractStrategy":"here"}
        """#.utf8)
        let settings = try JSONDecoder().decode(FinderSettings.self, from: legacy)
        expect(settings.isEnabled(.compressSevenZip), "旧配置里的 7Z 开关仍能读入")
        expect(settings.extractStrategy == .here, "旧配置里的 extractStrategy 仍能读入")

        // 设置页不再给这一项开关，但保存整份配置时不能把它丢掉
        _ = FinderSettingsStore.save(settings, to: file)
        let reloaded = FinderSettings.load(from: file)
        expect(reloaded.isEnabled(.compressSevenZip), "写回后 7Z 开关还在")
        expect(reloaded.enabled == settings.enabled, "开启列表逐项一致")
        expect(reloaded.extractStrategy == .here, "extractStrategy 原样保留")

        try? FileManager.default.removeItem(at: file)
    } catch {
        expect(false, "访达配置兼容 抛出异常", "\(error)")
    }
}

/// 清理缓存与真实预览交错：解压在飞时不许动
func testCacheInFlightPreview() {
    do {
        print("清理缓存 · 预览交错")
        MainActor.assumeIsolated {
            ScratchUsage.shared.reset()
            UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")

            let model = ArchiveModel()
            let zip = fixtures.appendingPathComponent("basic.zip")
            model.open(url: zip)
            guard waitUntil(15, { model.current != nil }) else {
                expect(false, "归档没打开，后续无从验证")
                return
            }
            guard let entry = model.current?.entries.first(where: { $0.path == "说明.txt" }) else {
                expect(false, "样例包里找不到 说明.txt")
                return
            }

            var payload: URL?
            model.payloadURL(for: entry) { payload = $0 }

            // 关键交错：payloadURL 刚派发、解压还在跑，这时候点「清理缓存」。
            // 旧实现只判 job != nil，会把这个临时目录整个删掉
            expect(ScratchUsage.shared.isWorking, "预览解压已登记为进行中")
            let during = model.clearCaches()
            expect(during.blocked, "预览解压期间清理被拒绝")
            expect(during.freedBytes == 0, "被拒绝时没有删除任何东西")

            guard waitUntil(20, { payload != nil }) else {
                expect(false, "预览文件没有产出")
                return
            }
            let url = payload!
            expect(FileManager.default.fileExists(atPath: url.path), "预览文件还在")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            expect(text.contains("hello"), "预览文件内容完整", text)

            expect(waitUntil(5, { !ScratchUsage.shared.isWorking }), "任务结束后登记被释放")
            ScratchUsage.shared.reset()
        }
    } catch {
        expect(false, "清理缓存·预览交错 抛出异常", "\(error)")
    }
}

/// 已被界面占用的文件：跳过一个，其余照清
func testCacheHeldPreviewFile() {
    do {
        print("清理缓存 · 占用的文件")
        let fm = FileManager.default
        ScratchUsage.shared.reset()
        let root = fixtures.appendingPathComponent("cache-held", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let held = root.appendingPathComponent("preview.txt")
        let other = root.appendingPathComponent("thumb.png")
        try Data(count: 300).write(to: held)
        try Data(count: 500).write(to: other)

        ScratchUsage.shared.hold(held)
        let report = CacheMaintenance.purge([root], busy: false)
        expect(report.inUse == 1, "占用的文件被跳过", "\(report.inUse)")
        expect(!report.blocked, "只跳过占用的，不整体拒绝")
        expect(report.freedBytes == 500, "其余文件照常清掉", "\(report.freedBytes)")
        expect(fm.fileExists(atPath: held.path), "占用的文件还在")
        expect(!fm.fileExists(atPath: other.path), "没占用的文件被删")
        expect(report.text.contains("正在使用"), "结果里说明跳过了什么", report.text)
        expect(report.succeeded, "跳过占用不算失败")

        // 「目录里某个文件被占用」也要保护：删的是父目录
        let folder = root.appendingPathComponent("scratch/深层", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let inner = folder.appendingPathComponent("payload.bin")
        try Data(count: 200).write(to: inner)
        ScratchUsage.shared.hold(inner)
        let second = CacheMaintenance.purge([root], busy: false)
        expect(second.inUse >= 1, "父目录里有被占用的文件时整段跳过", "\(second.inUse)")
        expect(fm.fileExists(atPath: inner.path), "深层被占用的文件没被连带删除")

        // 释放后就能清干净
        ScratchUsage.shared.release(inner)
        ScratchUsage.shared.release(held)
        let third = CacheMaintenance.purge([root], busy: false)
        expect(third.inUse == 0 && third.freedBytes > 0, "释放后正常清理", "\(third.freedBytes)")
        expect(((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty, "目录清空")

        ScratchUsage.shared.reset()
        try? fm.removeItem(at: root)
    } catch {
        expect(false, "清理缓存·占用的文件 抛出异常", "\(error)")
    }
}

/// 根目录读不出来：不能当空目录报成功
func testCacheUnreadableRoot() {
    do {
        print("清理缓存 · 读不出的目录")
        let fm = FileManager.default
        ScratchUsage.shared.reset()
        let root = fixtures.appendingPathComponent("cache-unreadable", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(count: 100).write(to: root.appendingPathComponent("x.bin"))

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        let report = CacheMaintenance.purge([root], busy: false)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        expect(report.unreadable == 1, "读不出的根目录被记下来", "\(report.unreadable)")
        expect(!report.succeeded, "读不出来不算成功")
        expect(report.text.contains("读不出来"), "结果说明读不出来", report.text)
        expect(report.text != "没有可清理的缓存", "不能报成「没有可清理的缓存」")
        expect(fm.fileExists(atPath: root.appendingPathComponent("x.bin").path),
               "文件没被误删（也没被误报成已清）")

        ScratchUsage.shared.reset()
        try? fm.removeItem(at: root)
    } catch {
        expect(false, "清理缓存·读不出的目录 抛出异常", "\(error)")
    }
}

/// 内嵌预览持续显示期间清缓存：文件不能被删
func testCacheWhilePreviewVisible() {
    do {
        print("清理缓存 · 内嵌预览")
        let fm = FileManager.default
        ScratchUsage.shared.reset()
        let zip = fixtures.appendingPathComponent("basic.zip")
        let root = fixtures.appendingPathComponent("cache-preview", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 复刻真实顺序：预览面板已经把条目解到临时目录，解压 worker 已结束
        let folderA = root.appendingPathComponent("preview-a", isDirectory: true)
        try fm.createDirectory(at: folderA, withIntermediateDirectories: true)
        try ArchiveService.extract(zip, entries: ["说明.txt"], to: folderA, password: nil)
        let shown = folderA.appendingPathComponent("说明.txt")
        expect(fm.fileExists(atPath: shown.path), "预览副本已解出")

        // 详情栏挂上这个 URL → 登记占用（PreviewPane.load 就是这么做的）
        ScratchUsage.shared.hold(shown)
        expect(!ScratchUsage.shared.isWorking, "解压已结束，只剩界面占用这一条线索")

        let first = CacheMaintenance.purge([root], busy: false)
        expect(!first.blocked, "不整体拒绝：只跳过被占用的那个")
        expect(first.inUse == 1, "占用的预览文件被登记", "\(first.inUse)")
        expect(fm.fileExists(atPath: shown.path), "正在显示的文件没被删")
        let text = (try? String(contentsOf: shown, encoding: .utf8)) ?? ""
        expect(text.contains("hello"), "内容完整，音视频不会被抽走底下的文件", text)

        // 预览一直开着，用户又点了一次清理
        let second = CacheMaintenance.purge([root], busy: false)
        expect(fm.fileExists(atPath: shown.path), "持续显示期间反复清理都不删")
        expect(second.inUse == 1, "每次都如实报「正在使用」")
        expect(second.freedBytes == 0, "没有别的可清时就是 0", "\(second.freedBytes)")

        // 切换条目：旧的释放、新的占用（新条目自己解一份）
        ScratchUsage.shared.release(shown)
        let folderB = root.appendingPathComponent("preview-b", isDirectory: true)
        try fm.createDirectory(at: folderB, withIntermediateDirectories: true)
        try ArchiveService.extract(zip, entries: ["带 空格.txt"], to: folderB, password: nil)
        let next = folderB.appendingPathComponent("带 空格.txt")
        expect(fm.fileExists(atPath: next.path), "新条目的副本已解出")
        ScratchUsage.shared.hold(next)
        let third = CacheMaintenance.purge([root], busy: false)
        expect(!fm.fileExists(atPath: shown.path), "切走之后旧副本可以清掉")
        expect(fm.fileExists(atPath: next.path), "新条目的副本保留")

        // 收起详情栏 / 关闭预览：释放后能清空
        ScratchUsage.shared.release(next)
        let fourth = CacheMaintenance.purge([root], busy: false)
        expect(fourth.inUse == 0, "释放后不再有占用")
        expect(((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty, "目录清空")

        ScratchUsage.shared.reset()
        try? fm.removeItem(at: root)
    } catch {
        expect(false, "清理缓存·内嵌预览 抛出异常", "\(error)")
    }
}

func runSettingsTests() {
    testServiceExtraction()
    testFinderSettingsStore()
    testExtractDestinationSetting()
    testWorkspaceModeFromSettings()
    testCacheMaintenance()
    testCacheInFlightPreview()
    testCacheHeldPreviewFile()
    testCacheUnreadableRoot()
    testCacheWhilePreviewVisible()
    testFinderConfigCompat()
}
