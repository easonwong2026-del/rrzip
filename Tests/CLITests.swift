// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Foundation

private func callCLI(_ arguments: [String]) -> (code: Int32?, out: String, error: String) {
    var output: [String] = []
    var errors: [String] = []
    let code = CLI.run(arguments, version: "9.8.7", stdout: { output.append($0) }, stderr: { errors.append($0) })
    return (code, output.joined(separator: "\n"), errors.joined(separator: "\n"))
}

func runCLITests() {
    print("命令行 · 参数、真实归档与安全预检")
    let fm = FileManager.default
    let root = fixtures.appendingPathComponent("cli", isDirectory: true)
    let archive = fixtures.appendingPathComponent("basic.zip")
    let output = root.appendingPathComponent("one/two")
    let original = Data("existing".utf8)
    let source = fixtures.appendingPathComponent("src/说明.txt")
    let newFile = output.appendingPathComponent("说明.txt")
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let help = callCLI(["--help"])
        expect(help.code == 0 && help.out.contains("--extract") && help.out.contains("--verify") && help.error.isEmpty,
               "中文帮助列出核心命令")
        expect(callCLI(["-h"]).out == help.out, "短帮助选项与长选项一致")
        expect(callCLI(["--version"]).out == "9.8.7" && callCLI(["-v"]).code == 0, "长短版本选项输出注入版本")
        expect(callCLI([]).code == nil && callCLI(["--full"]).code == nil, "GUI 参数继续交给窗口入口")
        let listing = callCLI(["--list", archive.path])
        expect(listing.code == 0 && listing.out.contains("说明.txt"), "保留列表输出")
        let detected = callCLI(["--detect", archive.path])
        expect(detected.code == 0 && detected.out.hasPrefix("zip\t"), "保留识别输出")
        for args in [["--typo"], ["--extract", archive.path], ["--extract", archive.path, "-o"],
                     ["--create", "bad.zip", source.path, "--level", "10"],
                     ["--create", "bad.ext", source.path], ["--list", archive.path, "--overwrite"],
                     ["--thumb", archive.path, "说明.txt", "unused.png", "--size", "-1"]] {
            let result = callCLI(args)
            expect(result.code == 1 && !result.error.isEmpty && result.out.isEmpty,
                   "拒绝错误用法 \(args.first ?? "")")
        }
        let created = root.appendingPathComponent("inferred.tar.gz")
        let made = callCLI(["--create", created.path, source.path, "--level", "0"])
        expect(made.code == 0 && made.error.isEmpty, "按 tar.gz 后缀和指定级别创建真实归档", made.error)
        expect(try InProcessArchive.list(created).map(\.path) == ["说明.txt"], "创建结果内容正确")
        let initial = callCLI(["--extract", archive.path, "-o", output.path, "说明.txt"])
        expect(initial.code == 0 && fm.fileExists(atPath: newFile.path), "选择性解压可以创建多层目标目录", initial.error)
        expect(!fm.fileExists(atPath: output.appendingPathComponent("带 空格.txt").path), "选择性解压仅发布所选条目")
        try original.write(to: newFile)
        let skip = callCLI(["--extract", archive.path, "-o", output.path])
        expect(skip.code == 0 && skip.out.contains("跳过 1 项"), "默认跳过同名，其他条目正常发布", skip.error)
        expect(try Data(contentsOf: newFile) == original, "默认解压保留旧文件")
        expect(fm.fileExists(atPath: output.appendingPathComponent("照片/城市/001.jpg").path), "发布缺失的整棵子目录")
        let overwrite = callCLI(["--extract", archive.path, "-o", output.path, "--overwrite", "说明.txt"])
        expect(overwrite.code == 0, "显式覆盖正常完成", overwrite.error)
        expect(try Data(contentsOf: newFile) == Data(contentsOf: source), "显式覆盖写入归档的内容")

        let blocked = root.appendingPathComponent("blocked")
        let badSelection = callCLI(["--extract", archive.path, "-o", blocked.path, "../bad"])
        expect(badSelection.code == 1 && badSelection.error.contains("不安全"), "拒绝逃逸的选中路径")
        expect(!fm.fileExists(atPath: blocked.path), "不安全的选择在创建目标前被拦截")

        let badSource = root.appendingPathComponent("unsafe-input")
        try fm.createDirectory(at: badSource, withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: badSource.appendingPathComponent("alias").path,
                                  withDestinationPath: "../../outside")
        try fm.copyItem(at: source, to: badSource.appendingPathComponent("safe.txt"))
        let unsafeTar = root.appendingPathComponent("unsafe.tar")
        try Tar.create(at: unsafeTar, from: [badSource], format: "tar")
        for selection in [[], ["unsafe-input/safe.txt"]] {
            let unsafe = callCLI(["--extract", unsafeTar.path, "-o", blocked.path, "--overwrite"] + selection)
            expect(unsafe.code == 1 && unsafe.error.contains("不安全"), "整包和选择性解压都执行归档预检")
        }
        expect(!fm.fileExists(atPath: blocked.path), "非法归档没有写入目标目录")

        let picture = root.appendingPathComponent("photo.png")
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            expect(false, "生成缩略图 PNG 样本")
            return
        }
        try png.write(to: picture)
        let imageArchive = root.appendingPathComponent("photo.tar")
        try Tar.create(at: imageArchive, from: [picture], format: "tar")
        let thumbnail = root.appendingPathComponent("thumb.png")
        let thumb = callCLI(["--thumb", imageArchive.path, "--size", "10", "photo.png", thumbnail.path])
        expect(thumb.code == 0 && thumb.out.contains("10x5"), "--size 放在位置参数之间仍正确渲染", thumb.error)
        let rendered = NSBitmapImageRep(data: try Data(contentsOf: thumbnail))
        expect(rendered?.pixelsWide == 10 && rendered?.pixelsHigh == 5, "真实 PNG 尺寸是 10×5")
        expect(callCLI(["--thumb", imageArchive.path, "../photo.png", thumbnail.path]).code == 1,
               "缩略图拒绝不安全的路径")

        if SevenZip.isAvailable {
            let checked = callCLI(["--verify", archive.path])
            expect(checked.code == 0 && checked.out.hasPrefix("ok "), "归档校验通过", checked.error)
            let secure = fixtures.appendingPathComponent("secret.7z")
            expect(callCLI(["--verify", secure.path, "--pass", "wrong"]).code == 1, "校验拒绝错误密码")
            expect(callCLI(["--verify", secure.path, "--pass", "pw123"]).code == 0, "校验接受正确密码")
            let decrypted = root.appendingPathComponent("decrypted")
            let badPassword = callCLI(["--extract", secure.path, "-o", decrypted.path, "--pass", "wrong"])
            expect(badPassword.code == 1 && !fm.fileExists(atPath: decrypted.path), "错误密码不发布任何产物")
            let goodPassword = callCLI(["--extract", secure.path, "-o", decrypted.path, "--pass", "pw123"])
            expect(goodPassword.code == 0 && fm.fileExists(atPath: decrypted.appendingPathComponent("说明.txt").path),
                   "正确密码真实解压加密包", goodPassword.error)
            let explicit = root.appendingPathComponent("explicit.bin")
            let written = callCLI(["--create", explicit.path, source.path, "--format", "7z", "--level", "1", "--pass", "pw123"])
            expect(written.code == 0, "显式格式与密码用于真实创建", written.error)
            expect(callCLI(["--verify", explicit.path, "--pass", "pw123"]).code == 0, "新建加密包可以校验")
            let split = root.appendingPathComponent("split.zip")
            let volumes = callCLI(["--create", split.path, source.path, "--volume", "1k"])
            expect(volumes.code == 0 && fm.fileExists(atPath: split.path + ".001"),
                   "指定分卷大小真实发布分卷", volumes.error)

            let added = root.appendingPathComponent("add.txt")
            try Data("add".utf8).write(to: added)
            let editable = root.appendingPathComponent("edit.zip")
            try fm.copyItem(at: archive, to: editable)
            let addition = callCLI(["--add", editable.path, "--prefix", "sub", added.path])
            expect(addition.out == "added 1", "保留加入命令输出并处理无斜线的前缀", addition.error)
            expect(try ArchiveService.list(editable, password: nil).contains { $0.path == "sub/add.txt" },
                   "加入命令仍保留包内目录")
            expect(callCLI(["--remove", editable.path, "sub/add.txt"]).out == "removed 1", "保留删除命令输出")
            expect(try !ArchiveService.list(editable, password: nil).contains { $0.path == "sub/add.txt" },
                   "删除命令实际更新归档")
        }
    } catch { expect(false, "命令行集成测试", "\(error)") }
}
