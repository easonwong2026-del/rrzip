// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Foundation

/// 一层归档的条目
struct ArchiveEntry: Identifiable, Hashable {
    /// 用路径做标识：刷新列表后选中状态不会丢
    var id: String { path }
    let path: String
    let size: Int64
    let modified: String
    let mode: String

    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var isDirectory: Bool { mode.hasPrefix("d") || path.hasSuffix("/") }
    var isArchive: Bool { ArchiveKind.isArchive(ext: ext) }

    var displaySize: String { ByteFormatter.string(size) }
}

enum ArchiveKind {
    /// 可识别的后缀全部来自格式目录（含 jar / apk / cbz 这类别名）
    static let readable: Set<String> = {
        var set = Set(FormatCatalog.formats.flatMap(\.extensions))
        set.formUnion(FormatCatalog.compounds.flatMap(\.extensions))
        return set
    }()

    static let writable: Set<String> = ["zip", "7z", "tar", "tgz"]

    static func isArchive(ext: String) -> Bool { readable.contains(ext) }
}

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        if bytes < 0 { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 { value /= 1024; idx += 1 }
        return idx == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[idx])
    }
}

enum ArchiveError: LocalizedError {
    case tool(String)
    case cancelled
    case unsupported(String)
    case needsPassword
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .tool(let message): return message
        case .cancelled: return "已取消"
        case .unsupported(let ext): return "暂不支持 .\(ext) 格式"
        case .needsPassword: return "该压缩包已加密，需要密码"
        case .engineUnavailable: return "7-Zip 引擎不可用，请重新构建应用"
        }
    }
}

/// 解析该归档所用的引擎
enum ArchiveEngine {
    case libarchive
    case sevenZip
}

/// 系统 bsdtar（libarchive 3.7）
enum Tar {
    static let binary = "/usr/bin/tar"

    @discardableResult
    static func run(_ args: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["COPYFILE_DISABLE"] = "1"
        process.environment = env

        // stderr 写临时文件而不是管道：两个管道顺序读会在错误输出超过缓冲区时互等
        let out = Pipe()
        let errFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = errHandle
        try process.run()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? errHandle.close()
        let errData = (try? Data(contentsOf: errFile)) ?? Data()
        try? FileManager.default.removeItem(at: errFile)

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0
            || stderr.lowercased().contains("incorrect passphrase")
            || stderr.lowercased().contains("error exit delayed") {
            let reason = stderr.isEmpty ? stdout : stderr
            throw ArchiveError.tool(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    static func list(_ archive: URL, passphrase: String? = nil) throws -> [ArchiveEntry] {
        var args: [String] = []
        if let passphrase, !passphrase.isEmpty { args += ["--passphrase", passphrase] }
        args += ["-tvf", archive.path]

        let raw: String
        do {
            raw = try run(args)
        } catch let ArchiveError.tool(message) {
            if looksEncrypted(message) { throw ArchiveError.needsPassword }
            throw ArchiveError.tool(message)
        }

        var entries: [ArchiveEntry] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = parse(String(line)) else { continue }
            entries.append(entry)
        }
        return entries
    }

    static func looksEncrypted(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("passphrase")
            || lower.contains("password")
            || lower.contains("encrypted")
            || lower.contains("encryption")
    }

    private static func parse(_ line: String) -> ArchiveEntry? {
        let pattern = #"^([dlrwxst-]{10}[+@.]?)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+(\w{3}\s+\d+\s+[\d:]{4,5})\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 5,
              let modeRange = Range(match.range(at: 1), in: line),
              let sizeRange = Range(match.range(at: 2), in: line),
              let dateRange = Range(match.range(at: 3), in: line),
              let pathRange = Range(match.range(at: 4), in: line)
        else { return nil }

        let path = decodeEscapes(String(line[pathRange]))
        guard !path.isEmpty else { return nil }
        return ArchiveEntry(
            path: path,
            size: Int64(line[sizeRange]) ?? 0,
            modified: String(line[dateRange]),
            mode: String(line[modeRange])
        )
    }

    /// bsdtar 在非 UTF-8 locale 下会把非 ASCII 字节打印成 \NNN 八进制转义
    static func decodeEscapes(_ input: String) -> String {
        guard input.contains("\\") else { return input }
        var out: [UInt8] = []
        let chars = Array(input)
        var index = 0
        func octal(_ c: Character) -> Bool { c >= "0" && c <= "7" }
        while index < chars.count {
            if chars[index] == "\\", index + 3 < chars.count,
               octal(chars[index + 1]), octal(chars[index + 2]), octal(chars[index + 3]),
               let byte = UInt8(String(chars[(index + 1)...(index + 3)]), radix: 8) {
                out.append(byte)
                index += 4
                continue
            }
            out.append(contentsOf: String(chars[index]).utf8)
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func extract(_ archive: URL, entries: [String], to destination: URL,
                        passphrase: String? = nil, keepExisting: Bool = false) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args: [String] = []
        if let passphrase, !passphrase.isEmpty { args += ["--passphrase", passphrase] }
        // 目标已存在同名文件时默认覆盖；keepExisting 走 bsdtar 的跳过语义
        if keepExisting { args.append("--keep-old-files") }
        args += ["-xf", archive.path, "-C", destination.path]
        if !entries.isEmpty { args.append(contentsOf: entries) }
        try run(args)
    }

    static func create(at output: URL, from items: [URL], format: String) throws {
        var args: [String] = []
        switch format {
        case "zip": args = ["-a", "-cf", output.path]
        case "tar": args = ["-cf", output.path]
        case "tgz": args = ["-czf", output.path]
        default: throw ArchiveError.unsupported(format)
        }
        args.append(contentsOf: items.map(\.path))
        try run(args)
    }
}

/// 应用内附带的 7-Zip 26.05（arm64）
/// 负责：创建 7z / 加密 / 分卷；以及 libarchive 读不了的加密头 7z
enum SevenZip {
    /// 依次尝试：主 bundle 的 Resources、以及「自己是 appex」时上级 app 的 Resources。
    /// 快捷查看和访达扩展里 `Bundle.main` 指向扩展自身，7zz 不在扩展包里；
    /// 这两条候选路径让三个 target 共用一份实现，不必各自注入。
    private static let candidates: [URL] = {
        var list: [URL] = []
        if let resources = Bundle.main.resourceURL {
            list.append(resources.appendingPathComponent("7zz"))
        }
        // <app>/Contents/PlugIns/<ext>.appex → <app>/Contents/Resources/7zz
        list.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/7zz")
        )
        return list
    }()

    /// 找一次就记住：每次解压都 stat 两个路径没必要
    private static let resolved: URL? = candidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }

    static var binary: URL? { resolved }

    static var isAvailable: Bool { binary != nil }

    @discardableResult
    static func run(_ args: [String], cwd: URL? = nil) throws -> String {
        guard let binary else { throw ArchiveError.engineUnavailable }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        process.environment = env

        let out = Pipe()
        let errFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = errHandle
        try process.run()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? errHandle.close()
        let errData = (try? Data(contentsOf: errFile)) ?? Data()
        try? FileManager.default.removeItem(at: errFile)

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let reason = stderr.isEmpty ? stdout : stderr
            throw ArchiveError.tool(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    /// 完整读一遍校验。损坏、密码不对都会抛错。
    static func verify(_ archive: URL, password: String? = nil) throws {
        var args = ["t", "-y"]
        if let password, !password.isEmpty { args.append("-p\(password)") }
        args.append(archive.path)
        try run(args)
    }

    /// `7zz l -slt` 的块状输出解析
    static func list(_ archive: URL, password: String? = nil) throws -> [ArchiveEntry] {
        var args = ["l", "-slt", "-ba"]
        if let password, !password.isEmpty { args.append("-p\(password)") }
        args.append(archive.path)

        let raw: String
        do {
            raw = try run(args)
        } catch let ArchiveError.tool(message) {
            let lower = message.lowercased()
            if lower.contains("password")
                || lower.contains("encrypted")
                || lower.contains("cannot open")
                || lower.contains("break signaled") {
                throw ArchiveError.needsPassword
            }
            throw ArchiveError.tool(message)
        }

        var entries: [ArchiveEntry] = []
        var current: [String: String] = [:]

        func flush() {
            defer { current = [:] }
            guard let path = current["Path"], !path.isEmpty else { return }
            let isFolder = (current["Folder"] ?? "-") == "+"
            let size = Int64(current["Size"] ?? "0") ?? 0
            let modified = current["Modified"] ?? ""
            entries.append(ArchiveEntry(
                path: path + (isFolder ? "/" : ""),
                size: isFolder ? 0 : size,
                modified: String(modified.prefix(16)),
                mode: isFolder ? "drwxr-xr-x" : (current["Attributes"] ?? "-rw-r--r--")
            ))
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            guard let range = line.range(of: " = ") else { continue }
            let key = String(line[line.startIndex..<range.lowerBound])
            let value = String(line[range.upperBound...])
            current[key] = value
        }
        flush()
        return entries
    }

    static func extract(_ archive: URL, entries: [String], to destination: URL,
                        password: String? = nil, skipExisting: Bool = false) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["x", "-y"]
        // -aos：已存在的文件跳过，不覆盖
        if skipExisting { args.append("-aos") }
        args.append("-o\(destination.path)")
        if let password, !password.isEmpty { args.append("-p\(password)") }
        args.append(archive.path)
        if !entries.isEmpty { args.append(contentsOf: entries) }
        try run(args)
    }

    /// format: "zip" | "7z" | "tar"
    static func create(
        at output: URL,
        from items: [URL],
        format: String,
        password: String?,
        volume: String?
    ) throws {
        var args = ["a", "-t\(format)", "-y"]
        if let password, !password.isEmpty {
            args.append("-p\(password)")
            if format == "zip" { args.append("-mem=AES256") }
            if format == "7z" { args.append("-mhe=on") }
        }
        if let volume, !volume.isEmpty { args.append("-v\(volume)") }
        args.append(output.path)
        args.append(contentsOf: items.map(\.path))
        try run(args)
    }

    // MARK: - 原地编辑

    /// 把文件加入归档。`prefix` 非空时放进对应子目录。
    /// 7-Zip 只保留文件基名，所以要落进子目录得先铺一层符号链接再以相对路径写入，
    /// 这样既不改目标内容，也不用复制大文件。
    static func add(_ archive: URL, items: [URL], prefix: String = "", password: String? = nil) throws {
        guard !items.isEmpty else { return }
        var base = ["a", "-y"]
        if let password, !password.isEmpty { base.append("-p\(password)") }

        if prefix.isEmpty {
            try run(base + [archive.path] + items.map(\.path))
            return
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-add-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var relatives: [String] = []
        for item in items {
            let target = folder.appendingPathComponent(item.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: item)
            relatives.append(prefix + item.lastPathComponent)
        }
        try run(base + [archive.path] + relatives, cwd: staging)
    }

    /// 从归档里删除条目（路径是包内路径，目录要带结尾斜杠）
    static func remove(_ archive: URL, entries: [String], password: String? = nil) throws {
        guard !entries.isEmpty else { return }
        var args = ["d", "-y"]
        if let password, !password.isEmpty { args.append("-p\(password)") }
        args.append(archive.path)
        args.append(contentsOf: entries)
        try run(args)
    }
}
