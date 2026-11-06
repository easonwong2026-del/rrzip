// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  访达扩展：菜单判定、任务计划与执行、转交

import Foundation

/// 访达菜单判定
func testFinderMenu() {
    do {
        print("访达菜单判定")
        do {
            let zip = fixtures.appendingPathComponent("basic.zip")
            let renamed = fixtures.appendingPathComponent("renamed.bin")
            let text = fixtures.appendingPathComponent("src/说明.txt")
            let folder = fixtures.appendingPathComponent("src/照片")

            let single = FinderSelection.inspect([zip])
            expect(single.archives.count == 1 && single.plain.isEmpty, "单个包归到压缩包")
            expect(FinderMenuBuilder.actions(for: single) == [.open, .extractHere, .extractToFolder],
                   "单包给 打开/解压到此处/解压到文件夹")
            expect(FinderMenuBuilder.title(for: .extractHere, in: single) == "解压到此处",
                   "单包标题不带数量")
            expect(FinderMenuBuilder.title(for: .extractToFolder, in: single) == "解压到「basic」",
                   "解压到文件夹带包名", FinderMenuBuilder.title(for: .extractToFolder, in: single))

            let byMagic = FinderSelection.inspect([renamed])
            expect(byMagic.archives.count == 1, "改名为 .bin 的 zip 按内容识别")
            expect(FinderMenuBuilder.actions(for: byMagic) == [.open, .extractHere, .extractToFolder],
                   "改名包同样给解压菜单")

            let noBudget = FinderSelection.inspect([renamed], magicBudget: 0)
            expect(noBudget.plain.count == 1 && noBudget.archives.isEmpty,
                   "魔数预算为 0 时不读文件，按普通文件处理")

            let many = FinderSelection.inspect([zip, renamed])
            expect(FinderMenuBuilder.actions(for: many) == [.open, .extractHere, .extractToFolder],
                   "多包仍是 3 项")
            expect(FinderMenuBuilder.title(for: .open, in: many) == "用 rrzip 打开第一个",
                   "多包打开文案说明只开第一个")
            expect(FinderMenuBuilder.title(for: .extractHere, in: many) == "解压 2 个压缩包到此处",
                   "多包解压标题带数量")
            expect(FinderMenuBuilder.title(for: .extractToFolder, in: many) == "分别解压到同名文件夹",
                   "多包解压到文件夹不拼包名")

            let oneFile = FinderSelection.inspect([text])
            expect(oneFile.archives.isEmpty && oneFile.plain.count == 1, "普通文件归到 plain")
            expect(FinderMenuBuilder.actions(for: oneFile) == [.compressZip, .compressSevenZip],
                   "单个普通文件不给「分别压缩」")
            // 沙盒扩展里没有 7zz，7Z 那一项不能摆出来
            expect(FinderMenuBuilder.actions(for: oneFile, canCreate7z: false) == [.compressZip],
                   "没有 7zz 时去掉「压缩为 7Z」")

            let twoItems = FinderSelection.inspect([text, folder])
            expect(twoItems.plain.count == 2, "目录算普通项目")
            expect(FinderMenuBuilder.actions(for: twoItems) == [.compressZip, .compressSevenZip, .compressEach],
                   "多选普通项目给「分别压缩」")
            expect(FinderMenuBuilder.title(for: .compressZip, in: twoItems) == "压缩 2 个项目为 ZIP",
                   "压缩标题带数量", FinderMenuBuilder.title(for: .compressZip, in: twoItems))

            let mixed = FinderSelection.inspect([zip, text])
            expect(FinderMenuBuilder.actions(for: mixed) == [.extractHere, .compressZip],
                   "混合选择只留双方都成立的动作")
            expect(FinderMenuBuilder.unsupportedNote(for: mixed) == nil, "没有不支持项时不加说明")

            let empty = FinderSelection.inspect([])
            expect(FinderMenuBuilder.actions(for: empty).isEmpty, "空选择不出菜单")
        }
    } catch {
        expect(false, "访达菜单判定 抛出异常", "\(error)")
    }
}

/// 访达任务计划
func testFinderPlanning() {
    do {
        print("访达任务计划")
        do {
            let zip = fixtures.appendingPathComponent("basic.zip")

            // 设置：缺键不该让整份配置失效
            let partial = Data(#"{"secondLevel": false}"#.utf8)
            let settings = try JSONDecoder().decode(FinderSettings.self, from: partial)
            expect(settings.secondLevel == false, "读到显式配置项")
            expect(settings.enabled.count == FinderAction.allCases.count, "缺 enabled 时全部放行")
            expect(settings.extractStrategy == .newFolder, "缺 extractStrategy 时默认新建文件夹")
            expect(settings.filtered([.open, .extractHere]) == [.open, .extractHere], "默认全部开启")

            var onlyOpen = FinderSettings()
            onlyOpen.enabled = ["open"]
            expect(onlyOpen.filtered([.open, .extractHere, .compressZip]) == [.open],
                   "设置里关掉的项从菜单消失")

            // 设置落盘：设置页写、扩展读，中间不能有半截 JSON
            let settingsFile = fixtures.appendingPathComponent("finder.json")
            var saved = FinderSettings()
            saved.secondLevel = false
            saved.enabled = ["open", "extractHere"]
            saved.extractStrategy = .here
            FinderSettingsStore.save(saved, to: settingsFile)
            expect(FinderSettings.load(from: settingsFile) == saved, "写盘后能原样读回")
            expect(!FileManager.default.fileExists(
                atPath: fixtures.appendingPathComponent(".finder.json.tmp").path),
                "临时文件没有留在原地")

            // 解压到此处：落点是源目录，冲突一律跳过而不是覆盖
            let here = FinderJobPlanner.planExtraction(of: [zip], mode: .here)
            expect(here.count == 1, "一个包一条计划")
            expect(here[0].destination == zip.deletingLastPathComponent(), "落点是源目录")
            expect(here[0].onConflict == .skip, "解压到此处不覆盖")

            // 解压到包名文件夹：同名目录递增
            let work = fixtures.appendingPathComponent("plan-test", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let aZip = work.appendingPathComponent("a.zip")
            let aSeven = work.appendingPathComponent("a.7z")

            let fresh = FinderJobPlanner.planExtraction(of: [aZip], mode: .newFolder)
            expect(fresh[0].destination.lastPathComponent == "a", "解到包名文件夹")

            try FileManager.default.createDirectory(
                at: work.appendingPathComponent("a", isDirectory: true),
                withIntermediateDirectories: true)
            let taken = FinderJobPlanner.planExtraction(of: [aZip], mode: .newFolder)
            expect(taken[0].destination.lastPathComponent == "a 2", "目录已存在时递增", 
                   taken[0].destination.lastPathComponent)

            // 同一批里两个同名包不能都解到 a/ —— 第二个要预留避让
            let batch = FinderJobPlanner.planExtraction(of: [aZip, aSeven], mode: .newFolder)
            expect(batch[0].destination.lastPathComponent == "a 2", "批内第一个让开已有目录")
            expect(batch[1].destination.lastPathComponent == "a 3", "批内第二个继续避让",
                   batch[1].destination.lastPathComponent)

            // 通知文案：结论在前，数字在后
            var ok = JobOutcome()
            ok.succeeded = ["a.zip", "b.zip"]
            ok.destination = URL(fileURLWithPath: "/tmp/out")
            expect(FinderNoticeText.title(for: ok, verb: "解压") == "解压完成 · 2 个", "全部成功")
            expect(FinderNoticeText.body(for: ok) == "位置：out/", "副标题给落点")

            ok.skippedFiles = 3
            expect(FinderNoticeText.title(for: ok, verb: "解压") == "解压完成 2 个，跳过 3 个同名文件",
                   "跳过项报数量")

            var encrypted = JobOutcome()
            encrypted.needsPassword = ["secret.7z"]
            expect(FinderNoticeText.title(for: encrypted, verb: "解压") == "需要密码 · secret.7z",
                   "加密包优先报密码")
            expect(FinderNoticeText.body(for: encrypted)?.contains("输入密码") == true, "副标题说明怎么办")

            var broken = JobOutcome()
            broken.failed = [.init(name: "bad.zip", reason: "文件已损坏")]
            expect(FinderNoticeText.title(for: broken, verb: "解压") == "解压失败 · bad.zip", "全失败")
            expect(FinderNoticeText.body(for: broken) == "文件已损坏", "副标题给原因")

            let partialOutcome = JobOutcome(succeeded: ["a.zip"], skippedFiles: 0,
                                            needsPassword: [], failed: [.init(name: "b.7z", reason: "损坏")])
            expect(FinderNoticeText.title(for: partialOutcome, verb: "解压") == "解压完成 1 个，1 个失败",
                   "部分失败")
        }
    } catch {
        expect(false, "访达任务计划 抛出异常", "\(error)")
    }
}

/// 访达任务执行
func testFinderExecution() {
    do {
        print("访达任务执行")
        do {
            let zip = fixtures.appendingPathComponent("basic.zip")
            let work = fixtures.appendingPathComponent("exec-test", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let localZip = work.appendingPathComponent("basic.zip")
            try FileManager.default.copyItem(at: zip, to: localZip)

            // 1. 解到包名文件夹
            let first = FinderJobRunner.extract([localZip], mode: .newFolder)
            expect(first.succeeded == ["basic.zip"], "第一次解压成功", "\(first.failed)")
            expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("basic/说明.txt").path),
                   "解到包名子目录")

            // 2. 再解一次同一目录：应该另建 basic 2，不动第一份
            _ = FinderJobRunner.extract([localZip], mode: .newFolder)
            expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("basic 2/说明.txt").path),
                   "重名目录递增，不覆盖上一份")

            // 3. 解到此处：目标已存在同名文件时必须跳过而不是覆盖
            let hereDir = work.appendingPathComponent("here", isDirectory: true)
            try FileManager.default.createDirectory(at: hereDir, withIntermediateDirectories: true)
            let hereZip = hereDir.appendingPathComponent("basic.zip")
            try FileManager.default.copyItem(at: zip, to: hereZip)

            _ = FinderJobRunner.extract([hereZip], mode: .here)
            let target = hereDir.appendingPathComponent("说明.txt")
            try "ADMIN".write(to: target, atomically: true, encoding: .utf8)

            let second = FinderJobRunner.extract([hereZip], mode: .here)
            let content = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            expect(content.contains("ADMIN"), "已存在的同名文件没有被覆盖", content)
            expect(second.skippedFiles == 4,
                   "跳过数被记下来（basic.zip 里 4 个文件都已存在）", "\(second.skippedFiles)")

            // 4. 加密包：解压前就判出来，且不留空目录
            let secret = fixtures.appendingPathComponent("secret.7z")
            if FileManager.default.fileExists(atPath: secret.path) {
                let encrypted = FinderJobRunner.extract([secret], mode: .newFolder)
                expect(encrypted.needsPassword == ["secret.7z"], "加密包提前判为需要密码")
                expect(!FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("secret").path),
                       "不给加密包留空目录")
            }
        } catch {
            expect(false, "访达任务执行", "\(error)")
        }
    } catch {
        expect(false, "访达任务执行 抛出异常", "\(error)")
    }
}

/// 访达转交
func testPendingHandoff() {
    do {
        print("访达转交")
        do {
            let noticeURL = fixtures.appendingPathComponent("pending-notice.json")
            PendingNotice.write(title: "跳过 3 个", message: "已存在", to: noticeURL)
            let notice = PendingNotice.take(from: noticeURL)
            expect(notice?.title == "跳过 3 个", "提示能读回")
            expect(notice?.message == "已存在", "正文能读回")
            expect(PendingNotice.take(from: noticeURL) == nil, "读一次就清掉")

            let extractURL = fixtures.appendingPathComponent("pending-extract.json")
            PendingExtraction.write(archives: [URL(fileURLWithPath: "/tmp/a.7z")],
                                    mode: .newFolder, to: extractURL)
            let pending = PendingExtraction.read(from: extractURL)
            expect(pending?.mode == .newFolder, "解压意图能读回")
            expect(pending?.archives.first?.hasSuffix("a.7z") == true, "包路径能读回")
            PendingExtraction.clear(extractURL)
            expect(PendingExtraction.read(from: extractURL) == nil, "清掉后读不到")
        }
    } catch {
        expect(false, "访达转交 抛出异常", "\(error)")
    }
}

func runFinderTests() {
    testFinderMenu()
    testFinderPlanning()
    testFinderExecution()
    testPendingHandoff()
}
