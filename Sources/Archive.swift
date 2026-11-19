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
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .tool(let message): return message
        case .cancelled: return "已取消"
        case .unsupported(let ext): return "暂不支持 .\(ext) 格式"
        case .needsPassword: return "该压缩包已加密，需要密码"
        case .engineUnavailable: return "7-Zip 引擎不可用，请重新构建应用"
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
        if path.hasPrefix("/") || path.hasPrefix("\\") || path.contains("\0") {
            throw ArchiveError.unsafePath(path)
        }
        let segments = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if segments.contains("..") {
            throw ArchiveError.unsafePath(path)
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
        // 只有队列任务才登记进程归属。批量、预览这些临时进程不登记，
        // 否则会把当前任务的句柄顶掉，取消就打到别人身上了。
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
                       jobID: UUID? = nil) throws {
        var args: [String] = []
        switch format {
        case "zip": args = ["-a", "-cf", output.path]
        case "tar": args = ["-cf", output.path]
        case "tgz": args = ["-czf", output.path]
        default: throw ArchiveError.unsupported(format)
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

/// 当前任务的进程归属。
///
/// 只有队列任务（`submitJob`）才有 jobID；批量、预览、校验这些临时进程
/// **不注册**，否则会覆盖 current，让「取消 A」终止掉 B 的进程。
///
/// 时序上有三件事要分开：
/// - `claim` 占位（任务开始）
/// - `begin` / `endProcess` 登记与注销**单个子进程**
/// - `release` 释放整个任务
///
/// 中间那层必须单独存在：加密解压第一次密码错了会重试，第一个进程退出时
/// 就把 owner 清掉的话，第二次重试虽然还在跑，取消却已经无处可打。
///
/// 这几个方法是跨线程调的（主线程 claim / 取消，detached 里 spawn），
/// 所以状态统一收进 `State`，由 NSLock 保护。`nonisolated(unsafe)` 只是
/// 让编译器别管这块静态存储——并发安全由锁负责，不是靠它豁免掉的。
enum TaskRegistry {
    private struct State {
        var current: Process?
        var owner: UUID?
        /// 记录每个已请求取消的任务 ID，避免取消排队任务时覆写当前运行任务的取消标记
        var cancelledIDs: Set<UUID> = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    /// 所有读写都在锁里；返回值带出来，避免在锁内调外部代码（terminate 之类）
    private static func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    /// 任务开始前占位。已经请求过取消就直接抛错，连进程都不启动。
    static func claim(_ id: UUID) throws {
        let rejected = withState { state -> Bool in
            if state.cancelledIDs.remove(id) != nil {
                state.owner = nil
                state.current = nil
                return true
            }
            state.owner = id
            state.current = nil
            return false
        }
        if rejected { throw ArchiveError.cancelled }
    }

    /// 子进程启动后登记。不属于 owner 的进程一律不接管。
    static func begin(_ process: Process, for id: UUID) {
        let terminate = withState { state -> Bool in
            guard state.owner == id else { return false }
            state.current = process
            // claim 之后、begin 之前来的取消，在这里补一刀
            return state.cancelledIDs.contains(id)
        }
        if terminate { terminateWithFallback(process, for: id) }
    }

    /// 单个子进程退出：只注销这一个进程，owner 留给任务本身。
    /// 重试用第二个进程时，`begin` 还能把它挂上，取消照样打得着。
    static func endProcess(_ process: Process, for id: UUID) {
        withState { state in
            guard state.owner == id else { return }
            // 只清自己登记的那一个：万一有更新换代的进程，别把新的抹掉
            if state.current === process { state.current = nil }
        }
    }

    /// 任务真正结束（`finishJob` 里调）。这里才释放归属。
    static func release(_ id: UUID) {
        let leftover = withState { state -> Process? in
            state.cancelledIDs.remove(id)
            guard state.owner == id else { return nil }
            let running = state.current
            state.current = nil
            state.owner = nil
            return running
        }
        // 正常路径不会走到这儿（进程都已 waitUntilExit）；真留下活进程就是有 bug，
        // 与其让它在后台继续写用户的磁盘，不如收掉。
        if let leftover { terminateWithFallback(leftover, for: id) }
    }

    /// 只对当前 owner 生效。串行保证了同一时刻只有一个任务，
    /// 但临时进程可能正在跑——它们的取消由自己的调用方负责。
    static func cancel(_ id: UUID) {
        let target = withState { state -> Process? in
            state.cancelledIDs.insert(id)
            return state.owner == id ? state.current : nil
        }
        if let target { terminateWithFallback(target, for: id) }
    }

    /// 先发 SIGTERM；若 3 秒后子进程仍在运行且仍归属该任务，再升级 SIGKILL 兜底
    private static func terminateWithFallback(_ process: Process, for id: UUID) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
            let stillActive = withState { state in
                state.owner == id && state.current?.processIdentifier == pid && (state.current?.isRunning ?? false)
            }
            if stillActive {
                _ = kill(pid, SIGKILL)
            }
        }
    }

    /// 进程退出后判断：是我这个任务被取消了吗。
    /// 必须在 `endProcess` 之前问——owner 一放掉就无从判断了。
    static func wasCancelled(_ id: UUID) -> Bool {
        withState { $0.owner == id && $0.cancelledIDs.contains(id) }
    }

    // 测试用
    static var currentOwner: UUID? { withState { $0.owner } }
    static var pendingCancel: UUID? { withState { $0.cancelledIDs.first } }
    static var hasProcess: Bool { withState { $0.current != nil } }
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
            let reason = stderr.isEmpty ? stdout : stderr
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
    static func verify(_ archive: URL, password: String? = nil) throws {
        var args = ["t", "-y"]
        if let password, !password.isEmpty { args.append("-p\(password)") }
        args += ["--", archive.path]
        try run(args, captureOutput: false)
    }

    /// `7zz l -slt` 的块状输出解析
    static func list(_ archive: URL, password: String? = nil) throws -> [ArchiveEntry] {
        var args = ["l", "-slt", "-ba"]
        if let password, !password.isEmpty { args.append("-p\(password)") }
        args += ["--", archive.path]

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
