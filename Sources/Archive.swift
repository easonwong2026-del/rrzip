// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Darwin
import Foundation

/// 一层归档的条目
struct ArchiveEntry: Identifiable, Hashable {
    /// 用路径做标识：刷新列表后选中状态不会丢
    var id: String { path }
    let path: String
    let size: Int64
    let modified: String
    let mode: String
    let modifiedDate: Date?
    let symlinkTarget: String?

    init(path: String, size: Int64, modified: String, mode: String,
         modifiedDate: Date? = nil, symlinkTarget: String? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
        self.mode = mode
        self.modifiedDate = modifiedDate
        self.symlinkTarget = symlinkTarget
    }

    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var isDirectory: Bool { mode.hasPrefix("d") || path.hasSuffix("/") }
    var isSymlink: Bool { mode.hasPrefix("l") || symlinkTarget != nil }
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
    case unsafePath(String)
    case excessiveExpansion

    var errorDescription: String? {
        switch self {
        case .tool(let message): return message
        case .cancelled: return "已取消"
        case .unsupported(let ext): return "暂不支持 .\(ext) 格式"
        case .needsPassword: return "该压缩包已加密，需要密码"
        case .engineUnavailable: return "7-Zip 引擎不可用，请重新构建应用"
        case .excessiveExpansion: return "归档声明的解压体积与膨胀比异常，已中止解压"
        case .unsafePath(let path): return "检测到不安全的归档路径，已中止操作：\(path)"
        }
    }
}

/// 归档路径与参数安全校验，防范 Zip Slip、目录穿越及选项/listfile 注入
enum ArchivePathGuard {
    static func validateRelative(_ path: String, allowEmpty: Bool = false) throws {
        if path.isEmpty {
            if allowEmpty { return }
            throw ArchiveError.unsafePath(path)
        }
        if isAbsolute(path) || hasListSeparator(path) {
            throw ArchiveError.unsafePath(path)
        }
        let segments = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if segments.contains("..") {
            throw ArchiveError.unsafePath(path)
        }
    }

    private static func hasListSeparator(_ path: String) -> Bool {
        path.utf8.contains { $0 == 0 || $0 == 10 || $0 == 13 }
    }

    private static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("\\") ||
            (path.utf8.first.map { (65...90).contains($0) || (97...122).contains($0) } == true &&
             path.utf8.dropFirst().first == 58)
    }

    static func validateSymlink(_ target: String, at path: String) throws {
        try validateSymlinks([(path, target)])
    }

    static func validateSymlinks(_ links: [(path: String, target: String)], entryPaths: [String] = []) throws {
        guard !links.isEmpty else { return }
        for link in links {
            try validateRelative(link.path)
            guard !link.target.isEmpty, !isAbsolute(link.target), !hasListSeparator(link.target) else {
                throw ArchiveError.unsafePath("\(link.path) -> \(link.target)")
            }
        }

        // 两个引擎/格式对反斜杠的处理可能不同，两种路径解释都必须留在根目录内。
        try validateSymlinks(links, entryPaths: entryPaths, splitting: { $0 == "/" })
        if links.contains(where: { $0.path.contains("\\") || $0.target.contains("\\") }) ||
            entryPaths.contains(where: { $0.contains("\\") }) {
            try validateSymlinks(links, entryPaths: entryPaths, splitting: { $0 == "/" || $0 == "\\" })
        }
    }

    private static func validateSymlinks(
        _ links: [(path: String, target: String)], entryPaths: [String],
        splitting isSeparator: (Character) -> Bool
    ) throws {
        var targets: [String: [Substring]] = [:]
        for (path, target) in links {
            let key = path.split(whereSeparator: isSeparator).filter { $0 != "." }
                .joined(separator: "/").lowercased()
            let parts = target.split(whereSeparator: isSeparator)
            if let prior = targets.updateValue(parts, forKey: key), prior != parts {
                throw ArchiveError.unsafePath(path)
            }
        }
        // 归档可以包含指向目录的软链。其他归档条目不得借这些软链改变落点。
        for path in entryPaths + links.map(\.path) {
            var parent = ""
            for component in path.split(whereSeparator: isSeparator).filter({ $0 != "." }).dropLast() {
                if !parent.isEmpty { parent += "/" }
                parent += component.lowercased()
                if targets[parent] != nil { throw ArchiveError.unsafePath(path) }
            }
        }
        for (path, target) in links {
            var resolved = Array(path.split(whereSeparator: isSeparator).filter { $0 != "." }.dropLast())
            var pending = Array(target.split(whereSeparator: isSeparator).reversed())
            var hops = 0
            while let component = pending.popLast() {
                switch component {
                case ".": continue
                case "..":
                    guard resolved.popLast() != nil else { throw ArchiveError.unsafePath("\(path) -> \(target)") }
                default:
                    resolved.append(component)
                    let key = resolved.joined(separator: "/").lowercased()
                    if let nested = targets[key] {
                        hops += 1
                        guard hops <= 40 else { throw ArchiveError.unsafePath(path) }
                        resolved.removeLast()
                        pending.append(contentsOf: nested.reversed())
                    }
                }
            }
        }
    }

    static func validateContained(_ child: URL, within base: URL) throws {
        let basePath = base.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard childPath == basePath || childPath.hasPrefix(prefix) else {
            throw ArchiveError.unsafePath(child.path)
        }
    }

    static func guardTarOperand(_ name: String) -> String {
        if name.hasPrefix("-") || name.hasPrefix("@") {
            return "./" + name
        }
        return name
    }

    static func writeListFile(_ items: [String]) throws -> URL {
        // 创建归档时会传绝对源路径，只检查 listfile 的分隔符。
        if let invalid = items.first(where: hasListSeparator) {
            throw ArchiveError.unsafePath(invalid)
        }
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-list-\(UUID().uuidString).txt")
        let body = items.joined(separator: "\n") + "\n"
        guard let data = body.data(using: .utf8) else {
            throw ArchiveError.tool("无法编码条目列表")
        }
        let created = FileManager.default.createFile(
            atPath: listURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw ArchiveError.tool("无法创建临时条目列表文件")
        }
        return listURL
    }
}

/// 解析该归档所用的引擎
enum ArchiveEngine {
    case libarchive
    case sevenZip

    /// 这个引擎在当前环境里能不能用。扩展进程拿不到 7zz，
    /// 试它只会把真正的错误盖成 engineUnavailable
    var isAvailable: Bool {
        switch self {
        case .libarchive: return true
        case .sevenZip: return SevenZip.isAvailable
        }
    }
}

/// 系统 bsdtar（libarchive 3.7）
enum Tar {
    static let binary = "/usr/bin/tar"

    @discardableResult
    static func run(_ args: [String], cwd: URL? = nil, jobID: UUID? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["COPYFILE_DISABLE"] = "1"
        process.environment = env

        // stderr 写临时文件而不是管道：两个管道顺序读会在错误输出超过缓冲区时互等
        let out = Pipe()
        defer { try? out.fileHandleForReading.close() }
        let errFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(
            atPath: errFile.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        defer { try? FileManager.default.removeItem(at: errFile) }
        let errHandle = try FileHandle(forWritingTo: errFile)
        var errClosed = false
        defer { if !errClosed { try? errHandle.close() } }

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = errHandle
        try process.run()
        if let jobID { TaskRegistry.begin(process, for: jobID) }
        defer { if let jobID { TaskRegistry.endProcess(process, for: jobID) } }

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let wasCancelled = jobID.map { TaskRegistry.wasCancelled($0) } ?? false
        try? errHandle.close()
        errClosed = true
        let errData = (try? Data(contentsOf: errFile)) ?? Data()

        // 主动取消也会让退出码非 0，先把它和真正的失败分开
        if wasCancelled { throw ArchiveError.cancelled }

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
        let now = Date()
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = parse(String(line), now: now) else { continue }
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

    private static let listingRegex = try! NSRegularExpression(
        pattern: #"^([bcdhlprswxstST?-]{10}[+@.]?)\s+\S+\s+\S+\s+\S+\s+(\d+(?:\s*,\s*\d+)?)\s+([A-Za-z]{3}\s+\d+\s+(?:\d{4}|\d{1,2}:\d{2}))\s+(.*)$"#
    )
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func parse(_ line: String, now: Date = Date()) -> ArchiveEntry? {
        guard let match = listingRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let modeRange = Range(match.range(at: 1), in: line),
              let sizeRange = Range(match.range(at: 2), in: line),
              let dateRange = Range(match.range(at: 3), in: line),
              let pathRange = Range(match.range(at: 4), in: line)
        else { return nil }

        let mode = String(line[modeRange])
        var pathname = line[pathRange]
        var symlinkTarget: String?
        if mode.hasPrefix("l"), let arrow = pathname.range(of: " -> ") {
            symlinkTarget = decodeEscapes(String(pathname[arrow.upperBound...]))
            pathname = pathname[..<arrow.lowerBound]
        } else if mode.hasPrefix("h"), let link = pathname.range(of: " link to ") {
            pathname = pathname[..<link.lowerBound]
        }
        let path = decodeEscapes(String(pathname))
        guard !path.isEmpty else { return nil }
        let modified = String(line[dateRange])
        return ArchiveEntry(path: path, size: Int64(line[sizeRange]) ?? 0, modified: modified,
                            mode: mode, modifiedDate: parseDate(modified, now: now),
                            symlinkTarget: symlinkTarget)
    }

    private static func parseDate(_ raw: String, now: Date) -> Date? {
        let fields = raw.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, let month = months.firstIndex(of: String(fields[0])),
              let day = Int(fields[1]) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        if let year = Int(fields[2]) {
            return calendar.date(from: DateComponents(year: year, month: month + 1, day: day))
        }
        let time = fields[2].split(separator: ":")
        guard time.count == 2, let hour = Int(time[0]), let minute = Int(time[1]) else { return nil }
        var parts = DateComponents(year: calendar.component(.year, from: now), month: month + 1,
                                   day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: parts) else { return nil }
        // bsdtar 对最近的条目省略年份，年初列上一年末的日期时需要回拨一年。
        if date.timeIntervalSince(now) > 24 * 60 * 60, let year = parts.year {
            parts.year = year - 1
            return calendar.date(from: parts)
        }
        return date
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
                        passphrase: String? = nil, keepExisting: Bool = false,
                        jobID: UUID? = nil) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args: [String] = []
        if let passphrase, !passphrase.isEmpty { args += ["--passphrase", passphrase] }
        // 目标已存在同名文件时默认覆盖；keepExisting 走 bsdtar 的跳过语义
        if keepExisting { args.append("--keep-old-files") }
        for entry in entries { try ArchivePathGuard.validateRelative(entry) }
        args += ["-xf", archive.path, "-C", destination.path]
        if !entries.isEmpty {
            args.append("--")
            args.append(contentsOf: entries)
        }
        do {
            try run(args, jobID: jobID)
        } catch let ArchiveError.tool(message) where looksEncrypted(message) {
            throw ArchiveError.needsPassword
        }
    }

    static func create(at output: URL, from items: [URL], format: String,
                       gzipLevel: Int? = nil, jobID: UUID? = nil) throws {
        var args: [String] = []
        switch format {
        case "zip": args = ["-a", "-cf", output.path]
        case "tar": args = ["-cf", output.path]
        case "tgz": args = ["-czf", output.path]
        default: throw ArchiveError.unsupported(format)
        }
        if format == "tgz", let gzipLevel {
            args += ["--options", "gzip:compression-level=\(gzipLevel)"]
        }
        guard let first = items.first else { throw ArchiveError.tool("没有要压缩的内容") }

        // 以第一项的父目录为工作目录、传相对名。
        // 直接传绝对路径的话，包内会存成 Users/xxx/Documents/foo/…，
        // 解压出来凭空多出好几层；用户看到的就是「压出来的包是坏的」。
        let parent = first.deletingLastPathComponent()
        let relatives = items.map { item -> String in
            item.deletingLastPathComponent().path == parent.path
                ? ArchivePathGuard.guardTarOperand(item.lastPathComponent)
                : item.path   // 跨目录的少数情况退回绝对路径，至少不丢内容
        }
        args.append("--")
        args.append(contentsOf: relatives)
        try run(args, cwd: parent, jobID: jobID)
    }

    /// 用系统 ditto 打 zip。单源压缩走这条路：
    /// tar 的 zip 实现只 store（不压缩），1.3 GB 的目录压完还是 1.3 GB；
    /// ditto 走 deflate，而且 `--keepParent` 天然只保留源文件名，不会带绝对路径。
    ///
    /// 它是真进程，所以也要登记归属：没有 7zz 的机器上这是唯一的 ZIP 路径，
    /// 不登记的话「取消」按下去什么都不会发生。
    static func createZip(at output: URL, from item: URL, jobID: UUID? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                             "--", item.path, output.path]

        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        process.environment = env

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()
        if let jobID { TaskRegistry.begin(process, for: jobID) }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let wasCancelled = jobID.map { TaskRegistry.wasCancelled($0) } ?? false
        if let jobID { TaskRegistry.endProcess(process, for: jobID) }

        // 被取消时 ditto 的退出码也是非 0，得先分辨出来，
        // 否则用户点「取消」会收到一条「压缩失败」的错误框
        if wasCancelled { throw ArchiveError.cancelled }

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.tool(message.isEmpty ? "压缩失败：\(item.lastPathComponent)" : message)
        }
    }
}

/// 每个任务独立占位，子进程退出后仍保留占位，供引擎回退或密码重试使用。
enum TaskRegistry {
    private struct State {
        var claimed: Set<UUID> = []
        var processes: [UUID: Process] = [:]
        var cancelledIDs: Set<UUID> = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    private static func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    static func claim(_ id: UUID) throws {
        let rejected = withState { state in
            if state.cancelledIDs.remove(id) != nil { return true }
            state.claimed.insert(id)
            return false
        }
        if rejected { throw ArchiveError.cancelled }
    }

    static func begin(_ process: Process, for id: UUID) {
        let terminate = withState { state in
            guard state.claimed.contains(id) else { return false }
            state.processes[id] = process
            return state.cancelledIDs.contains(id)
        }
        if terminate { terminateWithFallback(process) }
    }

    static func endProcess(_ process: Process, for id: UUID) {
        withState { state in
            if state.processes[id] === process { state.processes[id] = nil }
        }
    }

    static func release(_ id: UUID) {
        let leftover = withState { state in
            state.cancelledIDs.remove(id)
            state.claimed.remove(id)
            return state.processes.removeValue(forKey: id)
        }
        if let leftover { terminateWithFallback(leftover) }
    }

    static func cancel(_ id: UUID) {
        let target = withState { state -> Process? in
            guard state.cancelledIDs.insert(id).inserted else { return nil }
            return state.processes[id]
        }
        if let target { terminateWithFallback(target) }
    }

    /// Process 保持到宽限期结束，只升级仍在运行的同一个子进程。
    private static func terminateWithFallback(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
            if process.isRunning { _ = kill(pid, SIGKILL) }
        }
    }

    static func wasCancelled(_ id: UUID) -> Bool {
        withState { $0.claimed.contains(id) && $0.cancelledIDs.contains(id) }
    }

    static func checkCancellation(_ id: UUID?) throws {
        if let id, wasCancelled(id) { throw ArchiveError.cancelled }
    }

    // 测试用
    static var currentOwner: UUID? { withState { $0.claimed.count == 1 ? $0.claimed.first : nil } }
    static var pendingCancel: UUID? { withState { $0.cancelledIDs.first } }
    static var hasProcess: Bool { withState { !$0.processes.isEmpty } }
    static func hasProcess(for id: UUID) -> Bool { withState { $0.processes[id] != nil } }
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

    /// 找一次就记住：每次解压都 stat 两个路径没必要。
    /// 两个扩展（快速查看 / 访达）是沙盒进程，spawn 包内 7zz 会被系统拒绝，
    /// 编译时用 ARCHIVE_EXTENSION 直接返回 nil，让 ArchiveService 只用 libarchive。
    /// zip / tar / rar / 非加密 7z 都读得动；dmg、加密 7z 在扩展里会明确报错，
    /// 而不是「菜单点了没反应」。
    private static let resolved: URL? = {
        #if ARCHIVE_EXTENSION
        return nil
        #else
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
        #endif
    }()

    static var binary: URL? { resolved }

    static var isAvailable: Bool { binary != nil }

    private static let percentRegex = try? NSRegularExpression(pattern: #"(\d{1,3})%"#)
    private static let diagnosticBufferLimit = 65_536

    @discardableResult
    static func run(_ args: [String], cwd: URL? = nil,
                    jobID: UUID? = nil,
                    captureOutput: Bool = true,
                    includeStdoutOnError: Bool = false,
                    onProgress: ((Double) -> Void)? = nil) throws -> String {
        guard let binary else { throw ArchiveError.engineUnavailable }
        let process = Process()
        process.executableURL = binary

        var fullArgs = args
        if onProgress != nil {
            // -bsp1：把百分比进度从 stderr 挪到 stdout，才和普通输出分得开
            fullArgs.insert("-bsp1", at: 1)
        }
        process.arguments = fullArgs
        if let cwd { process.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        process.environment = env

        let out = Pipe()
        defer { try? out.fileHandleForReading.close() }
        let errFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(
            atPath: errFile.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        defer { try? FileManager.default.removeItem(at: errFile) }
        let errHandle = try FileHandle(forWritingTo: errFile)
        var errClosed = false
        defer { if !errClosed { try? errHandle.close() } }

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = errHandle
        try process.run()
        if let jobID { TaskRegistry.begin(process, for: jobID) }
        defer { if let jobID { TaskRegistry.endProcess(process, for: jobID) } }

        // 有进度回调时边读边解析；非列表操作只保留最近 64 KB 用于错误诊断，防止大包进度输出 OOM
        var outData = Data()
        var tail = ""
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if captureOutput {
                outData.append(chunk)
            } else {
                outData.append(chunk)
                if outData.count > diagnosticBufferLimit {
                    outData = Data(outData.suffix(diagnosticBufferLimit))
                }
            }
            guard onProgress != nil,
                  let text = String(data: chunk, encoding: .utf8) else { continue }
            tail += text
            if let percent = lastPercent(in: tail) { onProgress?(percent) }
            // 只留最后一点文本，避免长任务把内存吃掉
            if tail.count > 200 { tail = String(tail.suffix(80)) }
        }

        process.waitUntilExit()
        let wasCancelled = jobID.map { TaskRegistry.wasCancelled($0) } ?? false
        try? errHandle.close()
        errClosed = true
        let errData = (try? Data(contentsOf: errFile)) ?? Data()

        if wasCancelled { throw ArchiveError.cancelled }

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let reason = stderr.isEmpty ? stdout : (includeStdoutOnError ? stderr + "\n" + stdout : stderr)
            throw ArchiveError.tool(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    /// 取文本里最后一个 `NN%`。
    /// 7zz 用 \b 退格原地刷新进度行，行内会堆着 0%、1%、2%…，按行取会拿到最早的。
    private static func lastPercent(in text: String) -> Double? {
        guard let regex = percentRegex else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        return Double(ns.substring(with: last.range(at: 1))).map { $0 / 100 }
    }

    /// 完整读一遍校验。损坏、密码不对都会抛错。
    static func verify(_ archive: URL, password: String? = nil, jobID: UUID? = nil) throws {
        var args = ["t", "-y"]
        if let password, !password.isEmpty { args.append("-p\(password)") }
        args += ["--", archive.path]
        do {
            try run(args, jobID: jobID, captureOutput: false, includeStdoutOnError: true)
        } catch let ArchiveError.tool(message) where looksEncrypted(message, archive: archive) {
            throw ArchiveError.needsPassword
        }
    }

    /// `7zz l -slt` 的块状输出解析
    static func list(_ archive: URL, password: String? = nil, jobID: UUID? = nil) throws -> [ArchiveEntry] {
        var args = ["l", "-slt", "-ba"]
        if let password, !password.isEmpty { args.append("-p\(password)") }
        args += ["--", archive.path]

        let raw: String
        do {
            raw = try run(args, jobID: jobID, includeStdoutOnError: true)
        } catch let ArchiveError.tool(message) where looksEncrypted(message, archive: archive) {
            throw ArchiveError.needsPassword
        }

        return parseList(raw)
    }

    private static func looksEncrypted(_ message: String, archive: URL) -> Bool {
        let archivePrefix = "ERROR: \(archive.path) : "
        return message.split(whereSeparator: \.isNewline).contains { line in
            let diagnostic: Substring
            if line.hasPrefix(archivePrefix) {
                diagnostic = line.dropFirst(archivePrefix.count)
            } else if line.hasPrefix("ERROR: ") {
                diagnostic = line.dropFirst("ERROR: ".count)
            } else {
                diagnostic = line
            }
            let text = diagnostic.trimmingCharacters(in: .whitespaces).lowercased()
            return text.hasPrefix("wrong password") || text.hasPrefix("can not open encrypted archive")
                || text.hasPrefix("cannot open encrypted archive") || text.hasPrefix("enter password")
                || text.hasPrefix("password is required") || text.hasPrefix("encrypted archive")
                || text.hasPrefix("data error in encrypted file") || text.hasPrefix("crc failed in encrypted file")
        }
    }

    static func parseList(_ raw: String) -> [ArchiveEntry] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var entries: [ArchiveEntry] = []
        var current: [String: String] = [:]

        func flush() {
            defer { current = [:] }
            guard let path = current["Path"], !path.isEmpty else { return }
            let attributes = current["Attributes"]
            let posixMode = attributes?.split(whereSeparator: \.isWhitespace).last
                .flatMap { $0.count == 10 ? String($0) : nil }
            let mode = current["Mode"].flatMap { $0.isEmpty ? nil : $0 } ?? posixMode
            let isFolder = current["Folder"] == "+" || mode?.hasPrefix("d") == true
            let size = Int64(current["Size"] ?? "0") ?? 0
            let modified = current["Modified"] ?? ""
            entries.append(ArchiveEntry(
                path: path + (isFolder ? "/" : ""),
                size: isFolder ? 0 : size,
                modified: String(modified.prefix(16)),
                mode: mode ?? (isFolder ? "drwxr-xr-x" : attributes ?? "-rw-r--r--"),
                modifiedDate: formatter.date(from: String(modified.prefix(19))),
                symlinkTarget: (current["Symbolic Link"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? current["Target"]).flatMap { $0.isEmpty ? nil : $0 }
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

    /// listfile 的参数尾段。**必须写在 `--` 之前**：7-Zip 的 `--` 只终止开关解析，
    /// 同时会让 `@file` 退化成普通文件名。实测（26.05）：
    ///   `x -- a.7z @list` 解出 0 个文件、`d -- a.7z @list` 静默不删、
    ///   `a -- a.7z @list` 报 `@list` 不存在。
    /// 条目是从 listfile 读进来的，不会被当成开关，所以这里不需要 `--`；
    /// `-spd` 关掉通配符，条目里的 [ ] * ? 按字面匹配，避免误删 / 误取。
    private static func listTail(_ archive: URL, listFile: URL) -> [String] {
        ["-scsUTF-8", "-spd", archive.path, "@\(listFile.path)"]
    }

    static func extract(_ archive: URL, entries: [String], to destination: URL,
                        password: String? = nil, skipExisting: Bool = false,
                        jobID: UUID? = nil,
                        onProgress: ((Double) -> Void)? = nil) throws {
        for entry in entries { try ArchivePathGuard.validateRelative(entry) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["x", "-y"]
        // -aos：已存在的文件跳过，不覆盖
        if skipExisting { args.append("-aos") }
        args.append("-o\(destination.path)")
        if let password, !password.isEmpty { args.append("-p\(password)") }
        var listFile: URL?
        defer {
            if let listFile { try? FileManager.default.removeItem(at: listFile) }
        }
        if !entries.isEmpty {
            let file = try ArchivePathGuard.writeListFile(entries)
            listFile = file
            args += listTail(archive, listFile: file)
        } else {
            args += ["--", archive.path]
        }
        do {
            try run(args, jobID: jobID, captureOutput: false, onProgress: onProgress)
        } catch let ArchiveError.tool(message) {
            let lower = message.lowercased()
            if lower.contains("wrong password")
                || lower.contains("password")
                || lower.contains("encrypted") {
                throw ArchiveError.needsPassword
            }
            throw ArchiveError.tool(message)
        }
    }

    /// format: "zip" | "7z" | "tar"
    static func create(
        at output: URL,
        from items: [URL],
        format: String,
        password: String?,
        volume: String?,
        level: Int? = nil,
        jobID: UUID? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) throws {
        // 7-Zip 按文件基名入包，两个不同目录下的同名文件会直接失败：
        // "Duplicate filename on disk / errno=2"。提前拦成人话，
        // 别让用户对着 errno 发懵——反正这类选择也没法塞进同一个包。
        try ensureUniqueNames(items)

        guard ["zip", "7z", "tar"].contains(format) else {
            throw ArchiveError.unsupported(format)
        }
        if let volume, !volume.isEmpty {
            let validVolume = volume.range(of: #"^\d+[bkmgtBKMGT]?$"#, options: .regularExpression) != nil
            guard validVolume else {
                throw ArchiveError.tool("无效的分卷大小参数：\(volume)")
            }
        }

        var args = ["a", "-t\(format)", "-y"]
        // -mx=0 存而不压，9 是极限；不传则用 7zz 默认（5）
        if let level { args.append("-mx=\(max(0, min(9, level)))") }
        if let password, !password.isEmpty {
            args.append("-p\(password)")
            if format == "zip" { args.append("-mem=AES256") }
            if format == "7z" { args.append("-mhe=on") }
        }
        if let volume, !volume.isEmpty { args.append("-v\(volume)") }
        let listFile = try ArchivePathGuard.writeListFile(items.map(\.path))
        defer { try? FileManager.default.removeItem(at: listFile) }
        args += listTail(output, listFile: listFile)
        try run(args, jobID: jobID, captureOutput: false, onProgress: onProgress)
    }

    /// 不同目录下的同名项：7-Zip 会拒绝，提前给可读的提示。
    /// 同一目录不可能有两个同名文件，所以冲突必然来自跨目录多选。
    private static func ensureUniqueNames(_ items: [URL]) throws {
        var seen: [String: URL] = [:]
        for item in items {
            let key = item.lastPathComponent.lowercased()
            if let previous = seen[key] {
                throw ArchiveError.tool(
                    "有两个「\(item.lastPathComponent)」在不同目录下：\n"
                    + "\(previous.deletingLastPathComponent().path)\n"
                    + "\(item.deletingLastPathComponent().path)\n"
                    + "请分开压缩，或先改掉其中一个的名字。"
                )
            }
            seen[key] = item
        }
    }

    // MARK: - 原地编辑

    /// 把文件加入归档。`prefix` 非空时放进对应子目录。
    /// 7-Zip 只保留文件基名，所以要落进子目录得先铺一层符号链接再以相对路径写入，
    /// 这样既不改目标内容，也不用复制大文件。
    static func add(_ archive: URL, items: [URL], prefix: String = "", password: String? = nil) throws {
        guard !items.isEmpty else { return }
        var base = ["a", "-y"]
        if let password, !password.isEmpty { base.append("-p\(password)") }

        try ArchivePathGuard.validateRelative(prefix, allowEmpty: true)

        if prefix.isEmpty {
            let listFile = try ArchivePathGuard.writeListFile(items.map(\.path))
            defer { try? FileManager.default.removeItem(at: listFile) }
            try run(base + listTail(archive, listFile: listFile), captureOutput: false)
            return
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("rrzip-add-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(prefix, isDirectory: true)
        try ArchivePathGuard.validateContained(folder, within: staging)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var relatives: [String] = []
        for item in items {
            try ArchivePathGuard.validateRelative(item.lastPathComponent)
            let target = folder.appendingPathComponent(item.lastPathComponent)
            try ArchivePathGuard.validateContained(target, within: staging)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: item)
            relatives.append(prefix + item.lastPathComponent)
        }
        let listFile = try ArchivePathGuard.writeListFile(relatives)
        defer { try? FileManager.default.removeItem(at: listFile) }
        try run(base + listTail(archive, listFile: listFile), cwd: staging, captureOutput: false)
    }

    /// 从归档里删除条目（路径是包内路径，目录要带结尾斜杠）
    static func remove(_ archive: URL, entries: [String], password: String? = nil) throws {
        guard !entries.isEmpty else { return }
        for entry in entries { try ArchivePathGuard.validateRelative(entry) }
        var args = ["d", "-y"]
        if let password, !password.isEmpty { args.append("-p\(password)") }
        let listFile = try ArchivePathGuard.writeListFile(entries)
        defer { try? FileManager.default.removeItem(at: listFile) }
        args += listTail(archive, listFile: listFile)
        try run(args, captureOutput: false)
    }
}
