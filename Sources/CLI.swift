// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Foundation

enum CLI {
    private static let commands: Set<String> = [
        "--help", "-h", "--version", "-v", "--detect", "--list", "--add", "--remove",
        "--thumb", "--verify", "--extract", "--create"
    ]
    private static let valueOptions: Set<String> = ["--pass", "--prefix", "--size", "-o", "--format", "--level", "--volume"]
    private static let windowOptions: Set<String> = [
        "--icons", "--search", "--compact", "--full", "--settings", "--goto", "--demo-hover"
    ]

    private static let help = """
        rrzip 命令行用法
          --help, -h                                           显示帮助
          --version, -v                                        显示版本
          --detect <文件>                                      识别归档格式
          --list <归档> [--pass <密码>]                         列出条目
          --verify <归档> [--pass <密码>]                       检查完整性
          --extract <归档> -o <目录> [--overwrite] [--pass <密码>] [条目...]
                                                              解压，默认跳过同名文件
          --create <输出归档> <源文件...> [--format zip|7z|tar|tgz]
                    [--level 0..9] [--volume <分卷>] [--pass <密码>]
                                                              创建归档，默认按扩展名选格式
          --add <归档> <源文件...> [--prefix <包内目录>] [--pass <密码>]
          --remove <归档> <包内条目...> [--pass <密码>]
          --thumb <归档> <包内条目> <输出 PNG> [--size <像素>] [--pass <密码>]
        以短横线开头的路径可放在 -- 之后。
        """

    @discardableResult
    static func run(_ arguments: [String],
                    version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    stdout: (String) -> Void = { print($0) },
                    stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32? {
        guard arguments.contains(where: commands.contains) else {
            guard let unknown = arguments.first(where: { $0.hasPrefix("--") && $0 != "--" && !windowOptions.contains($0) })
            else { return nil }
            stderr("error: 未知命令 \(unknown)，请使用 --help")
            return 1
        }
        do {
            let parsed = try parse(arguments)
            try execute(parsed, version: version, stdout: stdout)
            return 0
        } catch {
            stderr("error: \(error.localizedDescription)")
            return 1
        }
    }

    private struct Arguments {
        let command: String
        let operands: [String]
        let options: [String: String]
        let overwrite: Bool
    }

    private static func parse(_ arguments: [String]) throws -> Arguments {
        var command: String?
        var operands: [String] = []
        var options: [String: String] = [:]
        var overwrite = false
        var literal = false
        var tokens = arguments.makeIterator()
        while let token = tokens.next() {
            if literal { operands.append(token) }
            else if token == "--" { literal = true }
            else if commands.contains(token) {
                guard command == nil else { throw ArchiveError.tool("每次只能执行一个命令") }
                command = token
            } else if valueOptions.contains(token) {
                guard let value = tokens.next(), !value.isEmpty,
                      token == "--pass" || (!value.hasPrefix("--") && !commands.contains(value)) else {
                    throw ArchiveError.tool("\(token) 需要一个值")
                }
                guard options[token] == nil else { throw ArchiveError.tool("选项重复：\(token)") }
                options[token] = value
            } else if token == "--overwrite" {
                overwrite = true
            } else if token.hasPrefix("-") {
                throw ArchiveError.tool("未知选项 \(token)")
            } else {
                operands.append(token)
            }
        }
        guard let command else { throw ArchiveError.tool("缺少命令，请使用 --help") }
        let allowed: Set<String>
        switch command {
        case "--extract": allowed = ["-o", "--pass"]
        case "--create": allowed = ["--format", "--level", "--volume", "--pass"]
        case "--add": allowed = ["--prefix", "--pass"]
        case "--thumb": allowed = ["--size", "--pass"]
        case "--list", "--verify", "--remove": allowed = ["--pass"]
        default: allowed = []
        }
        if let invalid = options.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ArchiveError.tool("\(command) 不支持 \(invalid)")
        }
        guard !overwrite || command == "--extract" else { throw ArchiveError.tool("只有 --extract 支持 --overwrite") }
        return Arguments(command: command, operands: operands, options: options, overwrite: overwrite)
    }

    private static func execute(_ args: Arguments, version: String?, stdout: (String) -> Void) throws {
        let operands = args.operands
        let password = args.options["--pass"]
        switch args.command {
        case "--help", "-h":
            guard operands.isEmpty else { throw ArchiveError.tool("--help 不接收路径") }
            stdout(help)
            return
        case "--version", "-v":
            guard operands.isEmpty else { throw ArchiveError.tool("--version 不接收路径") }
            stdout(version ?? "未知版本")
            return
        default: break
        }

        guard let first = operands.first else { throw ArchiveError.tool("\(args.command) 需要路径，请使用 --help") }
        let url = URL(fileURLWithPath: first)
        let rest = Array(operands.dropFirst())
        switch args.command {
        case "--list", "--detect", "--verify":
            guard rest.isEmpty else { throw ArchiveError.tool("\(args.command) 只接收一个路径") }
            switch args.command {
            case "--list":
                for entry in try ArchiveService.list(url, password: password) {
                    stdout("\(entry.mode)\t\(entry.size)\t\(entry.modified)\t\(entry.path)")
                }
            case "--detect":
                guard let detection = FormatDetector.detect(url) else {
                    throw ArchiveError.tool("无法识别 \(url.lastPathComponent)")
                }
                stdout("\(detection.format.id)\t\(detection.displayName)\t\(detection.source.rawValue)")
                stdout("openable=\(detection.format.isOpenable)\tsevenZip=\(detection.format.sevenZipType ?? "-")")
            default:
                try ArchiveService.verify(url, password: password)
                stdout("ok \(url.path)")
            }
        case "--add":
            guard !rest.isEmpty else { throw ArchiveError.tool("--add 需要至少一个待加入的文件") }
            var prefix = args.options["--prefix"] ?? ""
            if !prefix.isEmpty, !prefix.hasSuffix("/") { prefix += "/" }
            try SevenZip.add(url, items: rest.map { URL(fileURLWithPath: $0) },
                             prefix: prefix, password: password)
            stdout("added \(rest.count)")
        case "--remove":
            try SevenZip.remove(url, entries: rest, password: password)
            stdout("removed \(rest.count)")
        case "--thumb":
            guard rest.count == 2 else { throw ArchiveError.tool("用法：--thumb <归档> <条目> <输出 PNG>") }
            let side = try number(args.options["--size"], defaultValue: 560, range: 1...4096, option: "--size")
            try thumbnail(url, entry: rest[0], output: URL(fileURLWithPath: rest[1]), password: password,
                          side: CGFloat(side), stdout: stdout)
        case "--extract":
            guard let output = args.options["-o"] else { throw ArchiveError.tool("--extract 需要 -o <目标目录>") }
            for entry in rest { try ArchivePathGuard.validateRelative(entry) }
            let destination = URL(fileURLWithPath: output, isDirectory: true)
            let plan = PlannedExtraction(archive: url, destination: destination,
                                         onConflict: args.overwrite ? .overwrite : .skip)
            let result = try FinderJobRunner.extract(plan, password: password, intoNewFolder: false,
                                                     jobID: nil, onProgress: nil, entries: rest, createDestination: true)
            stdout("ok \(destination.path)\t跳过 \(result.skipped) 项")
        case "--create":
            guard !rest.isEmpty else { throw ArchiveError.tool("--create 需要至少一个源文件") }
            let format = try createFormat(args.options["--format"], output: url)
            let volume = args.options["--volume"]
            let level = try number(args.options["--level"], defaultValue: 5, range: 0...9, option: "--level")
            if format == .tar || format == .tgz, password != nil || volume != nil {
                throw ArchiveError.tool("加密和分卷只支持 ZIP 或 7Z")
            }
            try ArchiveWriter.writeArchive(at: url, from: rest.map { URL(fileURLWithPath: $0) }, format: format,
                                           password: password ?? "", volume: volume, level: level,
                                           gzipLevel: args.options["--level"] == nil ? nil : level)
            stdout("ok \(url.path)")
        default:
            throw ArchiveError.tool("未知命令 \(args.command)")
        }
    }

    private static func number(_ value: String?, defaultValue: Int, range: ClosedRange<Int>, option: String) throws -> Int {
        guard let value else { return defaultValue }
        guard let integer = Int(value), range.contains(integer) else {
            throw ArchiveError.tool("\(option) 需要 \(range.lowerBound)…\(range.upperBound) 范围内的整数")
        }
        return integer
    }

    private static func createFormat(_ explicit: String?, output: URL) throws -> CreateFormat {
        let name = output.lastPathComponent.lowercased()
        let format = explicit?.lowercased() ?? (name.hasSuffix(".tar.gz") ? "tgz" : output.pathExtension.lowercased())
        switch format {
        case "zip": return .zip
        case "7z": return .sevenZip
        case "tar": return .tar
        case "tgz": return .tgz
        default: throw ArchiveError.tool("归档格式须为 zip、7z、tar 或 tgz")
        }
    }

    private static func thumbnail(_ archive: URL, entry: String, output: URL, password: String?, side: CGFloat,
                                  stdout: (String) -> Void) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("rrzip-thumb-\(UUID().uuidString)", isDirectory: true)
        let file = staging.appendingPathComponent(entry)
        try ArchivePathGuard.validateRelative(entry)
        try ArchivePathGuard.validateContained(file, within: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try ArchiveService.extract(archive, entries: [entry], to: staging, password: password, validateSelection: true)
        try ArchivePathGuard.validateContained(file.resolvingSymlinksInPath(), within: staging.resolvingSymlinksInPath())
        guard let image = ThumbnailStore.renderForTool(url: file, ext: file.pathExtension.lowercased(), maxPixel: side) else {
            throw ArchiveError.tool("渲染失败 \(entry)")
        }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ArchiveError.tool("编码失败")
        }
        try data.write(to: output, options: .atomic)
        stdout("ok \(image.width)x\(image.height) -> \(output.path)")
    }
}
