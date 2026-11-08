// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  进程内读归档：Quick Look 扩展起不了子进程，改走 libarchive。
//  这里拿它和 bsdtar 的结果对齐，保证两条路读同一份包得到同样的东西。

import Foundation

/// 与 `Tar.list` 逐项对齐：路径、大小、目录判定
func testInProcessMatchesTar() {
    print("进程内读取 · 与 bsdtar 对齐")
    for name in ["basic.zip", "bundle.tgz"] {
        let url = fixtures.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            expect(false, "样例包 \(name) 不存在")
            continue
        }
        do {
            let viaTar = try Tar.list(url, passphrase: nil)
            let viaLib = try InProcessArchive.list(url, passphrase: nil)
            expect(viaLib.count == viaTar.count, "\(name) 条目数一致",
                   "tar \(viaTar.count) / libarchive \(viaLib.count)")

            let tarMap = Dictionary(uniqueKeysWithValues: viaTar.map { ($0.path, $0) })
            var mismatch: String?
            for entry in viaLib {
                guard let other = tarMap[entry.path] else {
                    mismatch = "多出 \(entry.path)"; break
                }
                if other.size != entry.size { mismatch = "\(entry.path) 大小 \(other.size)≠\(entry.size)"; break }
                if other.isDirectory != entry.isDirectory { mismatch = "\(entry.path) 目录判定不一致"; break }
            }
            expect(mismatch == nil, "\(name) 每一项都对得上", mismatch ?? "")
        } catch {
            expect(false, "\(name) 进程内读取失败", "\(error)")
        }
    }
}

/// 改名 / 没后缀的包：按内容识别，不看后缀
func testInProcessSniffsContent() {
    print("进程内读取 · 按内容识别")
    let url = fixtures.appendingPathComponent("renamed.bin")
    guard FileManager.default.fileExists(atPath: url.path) else {
        expect(false, "样例包 renamed.bin 不存在")
        return
    }
    do {
        let entries = try InProcessArchive.list(url, passphrase: nil)
        expect(!entries.isEmpty, "改名的 zip 也能列出条目", "得到 \(entries.count) 项")
    } catch {
        expect(false, "改名的 zip 读取失败", "\(error)")
    }
}

/// 加密包：必须报「需要密码」，不能报成格式错误
func testInProcessEncryptedNeedsPassword() {
    print("进程内读取 · 加密包")
    let url = fixtures.appendingPathComponent("secret.7z")
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("  - 没有 secret.7z（缺 7zz），跳过")
        return
    }
    do {
        _ = try InProcessArchive.list(url, passphrase: nil)
        expect(false, "加密包没报错")
    } catch ArchiveError.needsPassword {
        expect(true, "加密包报需要密码")
    } catch {
        expect(false, "加密包报错类型不对", "\(error)")
    }

    // libarchive 不支持「头加密」的 7z（bsdtar 原话：The archive header is
    // encrypted, but currently not supported），给了密码也一样。这种场景的正确
    // 表现就是继续提示去主程序——那里有 7zz。
    do {
        _ = try InProcessArchive.list(url, passphrase: "pw123")
        expect(false, "头加密 7z 应当仍报需要密码")
    } catch ArchiveError.needsPassword {
        expect(true, "头加密 7z 即使给了密码也如实上报（由主程序处理）")
    } catch {
        expect(false, "头加密 7z 报错类型不对", "\(error)")
    }
}

/// 不是压缩包：给出真实原因，而不是一句笼统的失败
func testInProcessRejectsGarbage() {
    print("进程内读取 · 非法文件")
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rrzip-garbage-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        try Data("not an archive at all".utf8).write(to: url)
        _ = try InProcessArchive.list(url, passphrase: nil)
        expect(false, "垃圾文件竟然读出来了")
    } catch {
        let text = error.localizedDescription
        expect(text.contains("无法识别"), "给出可读的原因", text)
    }
}

func runInProcessArchiveTests() {
    testInProcessMatchesTar()
    testInProcessSniffsContent()
    testInProcessEncryptedNeedsPassword()
    testInProcessRejectsGarbage()
}
