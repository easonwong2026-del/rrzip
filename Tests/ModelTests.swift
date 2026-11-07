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

        // 真跑一个子进程再等它退出：owner 必须留着。
        // 以前这里是把整个任务释放掉，加密解压第二次重试就取消不了了。
        _ = try? Tar.run(["--version"], jobID: a)
        expect(TaskRegistry.currentOwner == a, "子进程退出只注销进程，不释放任务")
        expect(!TaskRegistry.hasProcess, "进程槽已经清空")

        // 取消别的任务，不能动当前这个
        TaskRegistry.cancel(b)
        expect(TaskRegistry.currentOwner == a, "取消别的 ID 不动 owner")

        TaskRegistry.release(a)
        expect(TaskRegistry.currentOwner == nil, "任务结束后释放归属")
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
        TaskRegistry.release(d)
    } catch {
        expect(false, "进程归属 抛出异常", "\(error)")
    }
}

/// 造一份压不动的数据：可压缩的文本一秒就完了，取消根本插不进去。
/// 用自造的伪随机数，不依赖 /dev/urandom 的读取速度。
@discardableResult
func makeNoiseFile(at url: URL, megabytes: Int) -> URL {
    var blob = Data(count: megabytes * 1024 * 1024)
    blob.withUnsafeMutableBytes { raw in
        var seed: UInt64 = 0x1234_5678
        for i in 0..<raw.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            raw[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
    }
    try? blob.write(to: url)
    return url
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
        makeNoiseFile(at: dir.appendingPathComponent("big.bin"), megabytes: 30)

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
        // 任务层面还没结束（队列那边才调 release），归属得留着
        expect(TaskRegistry.currentOwner == id, "取消后归属仍归本任务")
        TaskRegistry.release(id)
    } catch {
        expect(false, "真进程取消 抛出异常", "\(error)")
    }
}

/// TAR / TGZ 也有真进程：不传 jobID 时取消按下去没反应。
/// 这条直接压 30 MB 数据，中途取消，必须抛 cancelled 而不是「等它压完」。
func testTarProcessCancel() {
    do {
        print("TAR 进程取消")
        let dir = fixtures.appendingPathComponent("cancel-tar-src", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        makeNoiseFile(at: dir.appendingPathComponent("big.bin"), megabytes: 30)

        let id = UUID()
        try TaskRegistry.claim(id)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            TaskRegistry.cancel(id)
        }

        let out = fixtures.appendingPathComponent("cancel-real.tgz")
        try? FileManager.default.removeItem(at: out)

        let start = Date()
        var caught = false
        do {
            try Tar.create(at: out, from: [dir], format: "tgz", jobID: id)
        } catch ArchiveError.cancelled {
            caught = true
        } catch {
            // 退出码非 0 但没认出取消，下面的断言会报出来
        }
        let elapsed = Date().timeIntervalSince(start)

        expect(caught, "TGZ 进程被取消，抛的是 cancelled")
        expect(elapsed < 8, "TGZ 取消后很快返回", "\(Int(elapsed * 1000))ms")
        TaskRegistry.release(id)
    } catch {
        expect(false, "TAR 进程取消 抛出异常", "\(error)")
    }
}

/// writeArchive 的各条分支都要把 jobID 传下去。
/// 这条走普通 ZIP（7zz 分支），顺便验证取消不会动用户已有的同名包。
func testWriteArchiveCancelKeepsOldFile() {
    do {
        print("压缩取消不动旧包")
        guard SevenZip.isAvailable else {
            print("  - 跳过：7zz 不可用")
            return
        }

        let dir = fixtures.appendingPathComponent("cancel-write-src", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        makeNoiseFile(at: dir.appendingPathComponent("big.bin"), megabytes: 30)

        // 目标位置先放一个「用户的旧包」，取消后必须逐字节不变
        let out = fixtures.appendingPathComponent("cancel-write.zip")
        let old = Data("这不是压缩包，但是用户的文件".utf8)
        try old.write(to: out)

        let id = UUID()
        try TaskRegistry.claim(id)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            TaskRegistry.cancel(id)
        }

        let start = Date()
        var caught = false
        do {
            try ArchiveModel.writeArchive(at: out, from: [dir], format: .zip,
                                          password: "", volume: nil, level: 5, jobID: id)
        } catch ArchiveError.cancelled {
            caught = true
        } catch {
            // 同 TGZ：普通失败说明 wasCancelled 没认出来
        }
        let elapsed = Date().timeIntervalSince(start)
        TaskRegistry.release(id)

        expect(caught, "ZIP 取消抛 cancelled（writeArchive 传了 jobID）")
        expect(elapsed < 8, "ZIP 取消后很快返回", "\(Int(elapsed * 1000))ms")
        let after = (try? Data(contentsOf: out)) ?? Data()
        expect(after == old, "取消后旧包逐字节未变")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(
            at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".cancel-write-") }
        expect(leftovers.isEmpty, "取消后不留临时产物", leftovers.map(\.lastPathComponent).joined(separator: ","))
    } catch {
        expect(false, "压缩取消不动旧包 抛出异常", "\(error)")
    }
}

/// 没有 7zz 时 ZIP 走 ditto，它也是真进程，取消同样要生效。
/// 用「启动前就取消」把时间窗口做成确定的：begin 一登记就 terminate。
func testDittoCancel() {
    do {
        print("ditto 取消")
        let dir = fixtures.appendingPathComponent("cancel-ditto-src", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = makeNoiseFile(at: dir.appendingPathComponent("big.bin"), megabytes: 30)

        let out = fixtures.appendingPathComponent("cancel-ditto.zip")
        try? FileManager.default.removeItem(at: out)

        let id = UUID()
        try TaskRegistry.claim(id)
        TaskRegistry.cancel(id)   // 进程还没 spawn 就先按取消

        let start = Date()
        var caught = false
        do {
            try Tar.createZip(at: out, from: file, jobID: id)
        } catch ArchiveError.cancelled {
            caught = true
        } catch {
            // 走到这里说明 ditto 没登记、取消没生效
        }
        let elapsed = Date().timeIntervalSince(start)
        TaskRegistry.release(id)

        expect(caught, "ditto 被取消，抛的是 cancelled")
        expect(elapsed < 5, "ditto 取消后立刻返回", "\(Int(elapsed * 1000))ms")
        try? FileManager.default.removeItem(at: out)
    } catch {
        expect(false, "ditto 取消 抛出异常", "\(error)")
    }
}

/// 加密解压的第二次尝试还能取消。
/// 以前第一个进程一退出就把 owner 放了，重试的进程谁都不认，按取消没反应。
func testEncryptedRetryStillCancellable() {
    do {
        print("加密重试仍可取消")
        guard SevenZip.isAvailable else {
            print("  - 跳过：7zz 不可用")
            return
        }

        let dir = fixtures.appendingPathComponent("retry-src", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        makeNoiseFile(at: dir.appendingPathComponent("big.bin"), megabytes: 20)

        let archive = fixtures.appendingPathComponent("retry-secret.7z")
        try? FileManager.default.removeItem(at: archive)
        // 存储级别：加密本身才是要验的事，别把时间花在压缩上
        try SevenZip.create(at: archive, from: [dir], format: "7z",
                            password: "pw123", volume: nil, level: 0)

        let destination = fixtures.appendingPathComponent("retry-out", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)

        let id = UUID()
        try TaskRegistry.claim(id)

        // 第一次：密码错，7zz 起来又退出。这一步不该释放任务归属
        var firstFailed = false
        do {
            try SevenZip.extract(archive, entries: [], to: destination,
                                 password: "wrong", jobID: id)
        } catch ArchiveError.cancelled {
            // 不该是取消
        } catch {
            firstFailed = true
        }
        expect(firstFailed, "错误密码的第一次尝试失败")
        expect(TaskRegistry.currentOwner == id, "第一次尝试结束后归属还在")

        // 第二次：密码对了，但用户已经按了取消。取消必须打得着这个新进程
        TaskRegistry.cancel(id)
        let start = Date()
        var caught = false
        do {
            try SevenZip.extract(archive, entries: [], to: destination,
                                 password: "pw123", jobID: id)
        } catch ArchiveError.cancelled {
            caught = true
        } catch {
            // 没认出取消
        }
        let elapsed = Date().timeIntervalSince(start)
        TaskRegistry.release(id)

        expect(caught, "重试的进程能被取消")
        expect(elapsed < 5, "重试取消后很快返回", "\(Int(elapsed * 1000))ms")
        expect(TaskRegistry.currentOwner == nil, "release 之后没有残留归属")
    } catch {
        expect(false, "加密重试仍可取消 抛出异常", "\(error)")
    }
}

/// 共享状态要经得起多线程同时打。
/// 没有锁的话这里会崩或者留下半截状态；有锁则每次都收敛到同一个结果。
func testRegistryConcurrency() {
    do {
        print("进程归属并发")
        let id = UUID()
        try TaskRegistry.claim(id)

        // 八个线程一起取消 + 读状态，取消信号只有一个赢家，但不该崩
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<400 {
                    TaskRegistry.cancel(id)
                    _ = TaskRegistry.currentOwner
                    _ = TaskRegistry.wasCancelled(id)
                }
            }
        }
        group.wait()
        expect(TaskRegistry.currentOwner == id, "并发取消后 owner 没被写乱")
        expect(TaskRegistry.wasCancelled(id), "并发取消后信号是置上的")
        TaskRegistry.release(id)

        // 再来一轮：真进程被八个线程同时 terminate，仍然只死一次、很快返回
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["2"]
        try TaskRegistry.claim(id)
        try process.run()
        TaskRegistry.begin(process, for: id)

        let killers = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: killers) {
                TaskRegistry.cancel(id)
            }
        }
        killers.wait()
        let start = Date()
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(start)
        TaskRegistry.endProcess(process, for: id)
        TaskRegistry.release(id)

        expect(elapsed < 1.5, "并发取消把进程真的杀掉了", "\(Int(elapsed * 1000))ms")
    } catch {
        expect(false, "进程归属并发 抛出异常", "\(error)")
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

/// 首页快速压缩也要进同一条队列，而且不能在包还没生成时就报「已生成 ZIP」
func testQuickCompressQueue() {
    MainActor.assumeIsolated {
        print("首页快速压缩进队列")
        let model = ArchiveModel()
        let dir = fixtures.appendingPathComponent("quick-\(UUID().uuidString.prefix(6))",
                                                  isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("便签.txt")
        try? "hello\n".write(to: src, atomically: true, encoding: .utf8)

        final class Box: @unchecked Sendable {
            var result: JobResult?
            var output: URL?
        }
        let box = Box()

        // 先占住队列，快速压缩就只能排队
        model.submitJob(title: "占位", detail: "") { _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return .succeeded
        }
        expect(model.job?.title == "占位", "前台任务先跑")

        model.quickCompress([src]) { result, output in
            box.result = result
            box.output = output
        }
        expect(model.queuedCount == 1, "快速压缩排队，不与前台任务并行")
        expect(model.job?.title == "占位", "前台任务没被顶掉")
        expect(box.result == nil, "还没跑完就不写结果")
        expect(!model.status.hasPrefix("已生成"), "这时状态栏不能说已生成", model.status)

        var waited = 0
        while model.job != nil && waited < 1000 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            waited += 1
        }
        expect(box.result == .succeeded, "跑完后才回调成功", "\(String(describing: box.result))")
        if let output = box.output {
            expect(FileManager.default.fileExists(atPath: output.path), "ZIP 真的生成了", output.path)
        } else {
            expect(false, "回调带回了产物路径")
        }
        expect(model.status.hasPrefix("已生成"), "状态栏这时才是完成态", model.status)
        try? FileManager.default.removeItem(at: dir)
    }
}

/// 暂存打包也要排队：A 在压缩时提交 B，B 等着；取消 A，B 照常跑完。
func testStashPackQueuesBehindCompress() {
    MainActor.assumeIsolated {
        print("暂存打包排队")
        guard SevenZip.isAvailable else {
            print("  - 跳过：7zz 不可用")
            return
        }

        let root = fixtures.appendingPathComponent("stash-queue", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bigDir = root.appendingPathComponent("big", isDirectory: true)
        try? FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)
        makeNoiseFile(at: bigDir.appendingPathComponent("big.bin"), megabytes: 30)
        let aOut = root.appendingPathComponent("a.zip")
        let bOut = root.appendingPathComponent("b.zip")

        final class Box: @unchecked Sendable { var aResult: JobResult? }
        let box = Box()

        let model = ArchiveModel()
        model.addToStash(archive: fixtures.appendingPathComponent("basic.zip"),
                         path: "说明.txt", size: 6)

        model.submitJob(title: "压缩 A", detail: "a.zip") { jobID in
            let result: JobResult
            do {
                try await Task.detached {
                    try ArchiveModel.writeArchive(at: aOut, from: [bigDir], format: .zip,
                                                  password: "", volume: nil, level: 9,
                                                  jobID: jobID)
                }.value
                result = .succeeded
            } catch ArchiveError.cancelled {
                result = .cancelled
            } catch {
                result = .failed(error.localizedDescription)
            }
            box.aResult = result
            return result
        }
        expect(model.job?.title == "压缩 A", "A 先跑")

        // 等 7zz 真的压起来，取消才有意义
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        model.packStash(to: bOut)
        expect(model.queuedCount == 1, "暂存打包排队，不与 A 并行")
        expect(model.job?.title == "压缩 A", "前台任务没被顶掉")
        expect(!FileManager.default.fileExists(atPath: bOut.path), "排队期间不产出 ZIP")

        model.cancelJob()
        let drained = waitUntil(20) { model.job == nil && model.queuedCount == 0 }
        expect(drained, "取消 A 之后队列继续跑空")
        expect(box.aResult == .cancelled, "A 确实被取消", String(describing: box.aResult))
        expect(FileManager.default.fileExists(atPath: bOut.path), "B 照常产出 ZIP")
        let listed = (try? SevenZip.list(bOut))?.map(\.path) ?? []
        expect(listed.contains { $0.contains("说明") }, "ZIP 里是暂存项",
               listed.joined(separator: ","))
        expect(model.status.hasPrefix("已打包"), "状态栏是 B 的完成文案", model.status)
    }
}

/// 取消暂存打包：不动用户已有的同名 ZIP、清掉临时目录、不影响排队的下一个任务。
func testStashPackCancel() {
    MainActor.assumeIsolated {
        print("暂存打包取消")
        guard SevenZip.isAvailable else {
            print("  - 跳过：7zz 不可用")
            return
        }

        let root = fixtures.appendingPathComponent("stash-cancel", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bigDir = root.appendingPathComponent("big", isDirectory: true)
        try? FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)
        makeNoiseFile(at: bigDir.appendingPathComponent("big.bin"), megabytes: 30)

        // 存储级别的 7z：建包快，解出来的东西够大，取消有时间窗口
        let srcArchive = root.appendingPathComponent("src.7z")
        do {
            try SevenZip.create(at: srcArchive, from: [bigDir], format: "7z",
                                password: nil, volume: nil, level: 0)
        } catch {
            expect(false, "准备加密包", "\(error)")
            return
        }

        let out = root.appendingPathComponent("keep.zip")
        let old = Data("这是用户已有的同名 ZIP".utf8)
        try? old.write(to: out)

        final class Box: @unchecked Sendable {
            var nextRan = false
        }
        let box = Box()

        let model = ArchiveModel()
        model.addToStash(archive: srcArchive, path: "big/big.bin", size: 30 * 1024 * 1024)

        model.packStash(to: out)
        model.submitJob(title: "C", detail: "") { _ in
            box.nextRan = true
            return .succeeded
        }
        expect(model.job?.title == "正在打包暂存", "暂存打包开始")
        expect(model.queuedCount == 1, "C 排在后面")

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let before = stashTempDirs()
        model.cancelJob()

        let drained = waitUntil(20) { model.job == nil && model.queuedCount == 0 }
        expect(drained, "取消后队列跑空")
        expect(model.status == "已取消", "暂存打包的结果是取消", model.status)
        expect(box.nextRan, "取消 B 不影响排队的 C")
        let after = (try? Data(contentsOf: out)) ?? Data()
        expect(after == old, "取消不动用户已有的同名 ZIP")
        let leftovers = stashTempDirs().filter { before.contains($0) }
        expect(leftovers.isEmpty, "解出来的临时目录已清理", leftovers.joined(separator: ","))
    }
}

/// 暂存项解不出来时必须停：不给一个缺文件的 ZIP。
func testStashPackFailsWhenItemMissing() {
    MainActor.assumeIsolated {
        print("暂存打包失败即停")
        let root = fixtures.appendingPathComponent("stash-fail", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 1. 包里根本没有这个条目
        let out = root.appendingPathComponent("missing.zip")
        let before = stashTempDirs()
        let model = ArchiveModel()
        model.addToStash(archive: fixtures.appendingPathComponent("basic.zip"),
                         path: "根本没有.txt", size: 10)
        model.packStash(to: out)
        let finished = waitUntil(10) { model.job == nil }
        expect(finished, "任务结束，不会卡住")
        expect(!FileManager.default.fileExists(atPath: out.path), "失败不产出 ZIP")
        expect(model.errorMessage?.contains("根本没有") == true, "失败原因指名道姓",
               model.errorMessage ?? "nil")
        expect(model.status == "打包失败", "状态是打包失败", model.status)
        let leftovers = stashTempDirs().subtracting(before)
        expect(leftovers.isEmpty, "失败后不留临时目录", leftovers.joined(separator: ","))

        // 2. 加密包但没给密码：引擎报错也要变成失败，而不是空包
        let secret = fixtures.appendingPathComponent("secret.7z")
        if FileManager.default.fileExists(atPath: secret.path) {
            let out2 = root.appendingPathComponent("secret.zip")
            let model2 = ArchiveModel()
            model2.addToStash(archive: secret, path: "说明.txt", size: 6)
            model2.packStash(to: out2)
            _ = waitUntil(10) { model2.job == nil }
            expect(!FileManager.default.fileExists(atPath: out2.path), "加密包没密码也不产出 ZIP")
            expect(model2.errorMessage != nil, "加密包失败有原因", model2.errorMessage ?? "nil")
        }
    }
}

func runModelTests() {
    testBatchDestination()
    testOpenGate()
    testJobQueue()
    testProcessOwnership()
    testRealProcessCancel()
    testTarProcessCancel()
    testWriteArchiveCancelKeepsOldFile()
    testDittoCancel()
    testEncryptedRetryStillCancellable()
    testRegistryConcurrency()
    testQuickCompressQueue()
    testStashPackQueuesBehindCompress()
    testStashPackCancel()
    testStashPackFailsWhenItemMissing()
    testWorkspaceMode()
    testHome()
    testArchiveService()
    testSortAndStaging()
}
