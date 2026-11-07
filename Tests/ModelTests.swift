// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  模型层：批量、打开判定、工作模式、排序

import Foundation

/// 批量目标目录
func testBatchDestination() {
    do {
        print("批量目标目录")
        do {
            let root = fixtures.appendingPathComponent("batchroot", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("demo"), withIntermediateDirectories: true)

            let archive = URL(fileURLWithPath: "/tmp/demo.zip")
            let folder = BatchRunner.uniqueFolder(for: archive, in: root)
            expect(folder.lastPathComponent == "demo (2)", "重名时自动加序号", "实际 \(folder.lastPathComponent)")

            let fresh = BatchRunner.uniqueFolder(for: URL(fileURLWithPath: "/tmp/fresh.zip"), in: root)
            expect(fresh.lastPathComponent == "fresh", "不重名时用原名")
        } catch {
            expect(false, "批量目标目录", "\(error)")
        }
    } catch {
        expect(false, "批量目标目录 抛出异常", "\(error)")
    }
}

/// 打开入口判定
func testOpenGate() {
    do {
        print("打开入口判定")
        do {
            let original = try Data(contentsOf: fixtures.appendingPathComponent("basic.zip"))

            let bare = fixtures.appendingPathComponent("noext-\(UUID().uuidString.prefix(4))")
            try original.write(to: bare)
            if case .open(let detection) = OpenGate.decide(bare) {
                expect(detection.source == .magic, "无后缀 zip 按内容识别", "实际 \(detection.source)")
            } else {
                expect(false, "无后缀 zip 应判定为可打开")
            }

            let disguised = fixtures.appendingPathComponent("disguised-\(UUID().uuidString.prefix(4)).bin")
            try original.write(to: disguised)
            if case .open(let detection) = OpenGate.decide(disguised) {
                expect(detection.source == .magic, "改名成 .bin 仍可打开", "实际 \(detection.source)")
            } else {
                expect(false, "改名成 .bin 应判定为可打开")
            }

            let plain = fixtures.appendingPathComponent("plain-\(UUID().uuidString.prefix(4)).txt")
            try "hello\n".write(to: plain, atomically: true, encoding: .utf8)
            if case .unrecognized = OpenGate.decide(plain) {
                expect(true, "普通文本判定为无法识别")
            } else {
                expect(false, "普通文本不应被当成归档")
            }
        } catch {
            expect(false, "打开入口判定", "\(error)")
        }
    } catch {
        expect(false, "打开入口判定 抛出异常", "\(error)")
    }
}

/// 任务队列：单任务串行，第二个排队
func testJobQueue() {
    do {
        print("任务队列")
        MainActor.assumeIsolated {
            let model = ArchiveModel()
            expect(model.job == nil, "初始没有任务")

            final class Box: @unchecked Sendable { var order: [String] = [] }
            let box = Box()

            model.submitJob(title: "A", detail: "") { _ in
                try? await Task.sleep(nanoseconds: 80_000_000)
                box.order.append("A")
                return .succeeded
            }
            model.submitJob(title: "B", detail: "") { _ in
                box.order.append("B")
                return .succeeded
            }

            expect(model.job?.title == "A", "第一个立即开始")
            expect(model.queuedCount == 1, "第二个排队，不并行")
            expect(model.job?.queued == 1, "卡片上能看到排队数")

            var waited = 0
            while model.job != nil && waited < 300 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                waited += 1
            }
            expect(box.order == ["A", "B"], "串行执行且顺序不乱",
                   box.order.joined(separator: ","))
            expect(model.job == nil, "全部结束后没有当前任务")
            expect(model.queuedCount == 0, "队列已清空")

            // 失败要落成错误，且不能卡住队列
            model.submitJob(title: "C", detail: "") { _ in .failed("故意失败") }
            model.submitJob(title: "D", detail: "") { _ in .succeeded }
            expect(model.job?.title == "C", "失败的任务也会开始")
            waited = 0
            while model.job != nil && waited < 300 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                waited += 1
            }
            expect(model.errorMessage == "故意失败", "失败原因落在 errorMessage",
                   model.errorMessage ?? "nil")
            expect(model.queuedCount == 0, "失败不阻塞后面的任务")

            // 取消：只在有任务时有效，且不清空队列里排着的
            model.submitJob(title: "E", detail: "") { _ in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return .cancelled
            }
            model.submitJob(title: "F", detail: "") { _ in .succeeded }
            expect(model.job?.title == "E", "E 开始")
            model.cancelJob()
            expect(model.status == "正在取消…", "取消先显示「正在取消」")
            waited = 0
            while model.job != nil && waited < 300 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                waited += 1
            }
            expect(model.queuedCount == 0, "取消后队列继续跑完")
        }
    } catch {
        expect(false, "任务队列 抛出异常", "\(error)")
    }
}

/// 进程归属：临时进程不能顶掉当前任务，取消只认自己的 ID
func testProcessOwnership() {
    do {
        print("进程归属")
        let a = UUID()
        let b = UUID()

        try TaskRegistry.claim(a)
        expect(TaskRegistry.currentOwner == a, "队列任务占位成功")

        // 批量、预览这些入口启动进程时不传 jobID，不该接管 owner
        _ = try? Tar.run(["--version"], jobID: nil)
        expect(TaskRegistry.currentOwner == a, "临时进程不覆盖当前任务")

        // 取消别的任务，不能动当前这个
        TaskRegistry.cancel(b)
        expect(TaskRegistry.currentOwner == a, "取消别的 ID 不动 owner")

        TaskRegistry.finish(a)
        expect(TaskRegistry.currentOwner == nil, "完成后释放归属")
        // 取消的是 b，不是 a：a 完成时不该替 b 清掉信号
        expect(TaskRegistry.pendingCancel == b, "别的任务的取消信号不会被顺手清掉")

        // 提交后立刻取消：claim 直接拦下，连进程都不启动
        let c = UUID()
        TaskRegistry.cancel(c)
        var threw = false
        do { try TaskRegistry.claim(c) } catch { threw = true }
        expect(threw, "提交后立刻取消，claim 拦下不启动进程")

        // 上一个取消信号不能误伤下一个任务
        let d = UUID()
        try TaskRegistry.claim(d)
        expect(TaskRegistry.currentOwner == d, "过期信号不误伤下一个任务")
        TaskRegistry.finish(d)
    } catch {
        expect(false, "进程归属 抛出异常", "\(error)")
    }
}

/// 真进程取消：不是模拟返回 .cancelled，而是真的把 7zz 杀掉
func testRealProcessCancel() {
    do {
        print("真进程取消")
        guard SevenZip.isAvailable else {
            print("  - 跳过：7zz 不可用")
            return
        }

        let dir = fixtures.appendingPathComponent("cancel-src", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 30 MB 随机数据：压不动，-mx=9 要跑好几秒，取消才有机会插进去
        var blob = Data(count: 30 * 1024 * 1024)
        blob.withUnsafeMutableBytes { raw in
            var seed: UInt64 = 0x1234_5678
            for i in 0..<raw.count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                raw[i] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        try blob.write(to: dir.appendingPathComponent("big.bin"))

        let out = fixtures.appendingPathComponent("cancel-real.7z")
        try? FileManager.default.removeItem(at: out)

        let id = UUID()
        try TaskRegistry.claim(id)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            TaskRegistry.cancel(id)
        }

        let start = Date()
        var caught = false
        do {
            try SevenZip.create(at: out, from: [dir], format: "7z",
                                password: nil, volume: nil, level: 9, jobID: id)
        } catch ArchiveError.cancelled {
            caught = true
        } catch {
            // 被 SIGTERM 杀掉时退出码非 0；如果这里走了普通失败，
            // 说明 wasCancelled 没认出来，下面的断言会失败
        }
        let elapsed = Date().timeIntervalSince(start)

        expect(caught, "真进程被取消，抛的是 cancelled")
        expect(elapsed < 8, "取消后很快返回，不是等它压完", "\(Int(elapsed * 1000))ms")
    } catch {
        expect(false, "真进程取消 抛出异常", "\(error)")
    }
}

/// 工作模式
func testWorkspaceMode() {
    do {
        print("工作模式")
        MainActor.assumeIsolated {
            // 测试不受本机偏好影响
            UserDefaults.standard.removeObject(forKey: "rrzip.workspaceMode")
            let model = ArchiveModel()
            expect(model.workspaceMode == .compact, "默认简化模式")

            // 阈值全部从 Layout 推导，不再有写死的 760 / 900
            let collapse = Layout.autoCollapseWidth

            // 方向感知：同一个阈值，往宽拉展开、往窄拉收起，中间没有滞回死区。
            // 留 80pt 滞回那版，用户从 720 拉到 850 完全没反应。
            expect(model.autoMode(forWidth: 700) == nil, "第一帧没有方向信息，不动")
            expect(model.autoMode(forWidth: collapse + 10) == .full,
                   "往宽拉过阈值就展开", "collapse=\(collapse)")
            model.setWorkspaceMode(.full, manual: false)
            expect(model.autoMode(forWidth: collapse + 20) == nil, "已是完整模式，继续拉宽不动")

            // 阈值本身要自洽：这是上一版的 bug——判据低于窗口最小宽度，分支永远走不到
            expect(collapse >= Layout.fullModeMinWidth, "收起阈值不低于三栏几何下限",
                   "collapse=\(collapse)")
            expect(collapse <= 1020, "收起阈值不超过旧版窗口最小宽度，否则又会不可达",
                   "collapse=\(collapse)")

            // 完整模式被拖窄必须能收起（旧版这条永远返回 nil）
            expect(model.autoMode(forWidth: collapse - 1) == .compact, "拉窄到阈值以下自动收起")
            model.setWorkspaceMode(.compact, manual: false)
            expect(model.autoMode(forWidth: collapse + 1) == .full, "再拉宽回来又展开")

            model.selection = ["a", "b"]
            model.setWorkspaceMode(.full, manual: true)
            expect(model.selection == ["a", "b"], "切模式不动选中项")
            expect(model.autoMode(forWidth: 600) == nil, "手动切换后冷却期内不自动回简化")

            model.toggleWorkspaceMode()
            expect(model.workspaceMode == .compact, "再切回简化")
        }
    } catch {
        expect(false, "工作模式 抛出异常", "\(error)")
    }
}

/// 首页
func testHome() {
    do {
        print("首页")
        MainActor.assumeIsolated {
            UserDefaults.standard.removeObject(forKey: "rrzip.recentArchives")
            let model = ArchiveModel()
            model.recordRecent(URL(fileURLWithPath: "/tmp/a.zip"))
            model.recordRecent(URL(fileURLWithPath: "/tmp/b.7z"))
            model.recordRecent(URL(fileURLWithPath: "/tmp/a.zip"))
            expect(model.recentArchives.count == 2, "同一个包不重复记", "实际 \(model.recentArchives.count)")
            expect(model.recentArchives.first?.path == "/tmp/a.zip", "最近打开的排最前")
            model.clearRecentArchives()
            expect(model.recentArchives.isEmpty, "可以清空")
        }

        do {
            let folder = fixtures.appendingPathComponent("quick", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let first = folder.appendingPathComponent("demo.zip")
            try "x".write(to: first, atomically: true, encoding: .utf8)
            expect(ArchiveModel.uniqueOutput(first).lastPathComponent == "demo 2.zip",
                   "重名自动加序号", ArchiveModel.uniqueOutput(first).lastPathComponent)
            let fresh = folder.appendingPathComponent("fresh.zip")
            expect(ArchiveModel.uniqueOutput(fresh).lastPathComponent == "fresh.zip", "不重名用原名")
        } catch {
            expect(false, "快速压缩命名", "\(error)")
        }
    } catch {
        expect(false, "首页 抛出异常", "\(error)")
    }
}

/// ArchiveService
func testArchiveService() {
    do {
        print("ArchiveService")
        do {
            expect(ArchiveService.engineOrder(for: fixtures.appendingPathComponent("basic.zip")).first == .libarchive,
                   "zip 先用 libarchive")
            expect(ArchiveService.engineOrder(for: URL(fileURLWithPath: "/tmp/demo.dmg")).first == .sevenZip,
                   "dmg 先用 7-Zip")

            let entries = try ArchiveService.list(fixtures.appendingPathComponent("basic.zip"), password: nil)
            expect(entries.count == 6, "list 结果与单引擎一致", "实际 \(entries.count)")
            expect(ArchiveService.canOpen(fixtures.appendingPathComponent("basic.zip")), "canOpen 认得 zip")
            expect(!ArchiveService.canOpen(URL(fileURLWithPath: "/tmp/rrzip-not-an-archive.txt")), "普通文本判为不能开")

            let out = fixtures.appendingPathComponent("svc-out", isDirectory: true)
            try? FileManager.default.removeItem(at: out)
            try ArchiveService.extract(fixtures.appendingPathComponent("basic.zip"),
                                       entries: ["说明.txt"], to: out, password: nil)
            expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("说明.txt").path),
                   "extract 解出指定条目")
        } catch {
            expect(false, "ArchiveService", "\(error)")
        }

        if SevenZip.isAvailable {
            do {
                _ = try ArchiveService.list(fixtures.appendingPathComponent("secret.7z"), password: nil)
                expect(false, "加密包应抛 needsPassword")
            } catch ArchiveError.needsPassword {
                expect(true, "加密包抛 needsPassword")
            } catch {
                expect(false, "加密包应抛 needsPassword", "\(error)")
            }
        }
    } catch {
        expect(false, "ArchiveService 抛出异常", "\(error)")
    }
}

/// 排序与暂存
func testSortAndStaging() {
    do {
        print("排序与暂存")
        MainActor.assumeIsolated {
            let model = ArchiveModel()
            let big = ArchiveEntry(path: "b.txt", size: 300, modified: "2026-01-02 10:00", mode: "-rw-r--r--")
            let small = ArchiveEntry(path: "a.txt", size: 100, modified: "2026-01-03 10:00", mode: "-rw-r--r--")
            let folder = ArchiveEntry(path: "z/", size: 0, modified: "2026-01-01 10:00", mode: "drwxr-xr-x")

            model.sortKey = .name
            model.sortAscending = true
            expect(model.sortEntries([big, folder, small]).map(\.name) == ["z", "a.txt", "b.txt"],
                   "名称升序且目录在前", model.sortEntries([big, folder, small]).map(\.name).joined(separator: ","))

            model.sortKey = .size
            model.sortAscending = true
            expect(model.sortEntries([big, small]).map(\.size) == [100, 300], "按大小升序")

            model.sortAscending = false
            expect(model.sortEntries([big, small]).map(\.size) == [300, 100], "再点一次变降序")
        }

        do {
            let item = StashItem(archive: fixtures.appendingPathComponent("basic.zip"),
                                 path: "说明.txt", size: 0)

            let perArchive = fixtures.appendingPathComponent("stash-out", isDirectory: true)
            try? FileManager.default.removeItem(at: perArchive)
            try FileManager.default.createDirectory(at: perArchive, withIntermediateDirectories: true)
            let placed = try ArchiveModel.exportStashItem(item, to: perArchive, layout: .perArchive, password: nil)
            expect(FileManager.default.fileExists(atPath: placed.path), "按包分目录导出成功")
            expect(placed.path.contains("/basic/"), "落在包名子目录里", placed.path)

            let flat = fixtures.appendingPathComponent("stash-flat", isDirectory: true)
            try? FileManager.default.removeItem(at: flat)
            try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
            let first = try ArchiveModel.exportStashItem(item, to: flat, layout: .flat, password: nil)
            let second = try ArchiveModel.exportStashItem(item, to: flat, layout: .flat, password: nil)
            expect(first.lastPathComponent == "说明.txt", "平铺保留原文件名", first.lastPathComponent)
            expect(second.lastPathComponent == "说明 2.txt", "同名自动加序号", second.lastPathComponent)
        } catch {
            expect(false, "暂存落盘", "\(error)")
        }
    } catch {
        expect(false, "排序与暂存 抛出异常", "\(error)")
    }
}

func runModelTests() {
    testBatchDestination()
    testOpenGate()
    testJobQueue()
    testProcessOwnership()
    testRealProcessCancel()
    testWorkspaceMode()
    testHome()
    testArchiveService()
    testSortAndStaging()
}
