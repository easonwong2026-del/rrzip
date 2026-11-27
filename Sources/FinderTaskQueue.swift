// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Darwin
import Foundation

struct FinderFileRef: Codable, Sendable, Equatable {
    let path: String
    var bookmarkData: Data?
    let displayName: String

    init(url: URL, bookmarkData: Data? = nil) {
        path = url.path
        self.bookmarkData = bookmarkData
        displayName = url.lastPathComponent
    }

    var isValid: Bool {
        path.hasPrefix("/") && path != "/" &&
            !path.utf8.contains { $0 == 0 || $0 == 10 || $0 == 13 } &&
            !path.split(separator: "/").contains("..") &&
            !displayName.isEmpty && displayName.utf8.count <= 1024 &&
            !displayName.utf8.contains { $0 == 0 || $0 == 10 || $0 == 13 }
    }
}

struct FinderTaskRequest: Codable, Sendable, Equatable {
    enum Operation: String, Codable, Sendable {
        case extractHere, extractToFolder, compressZip, compressSevenZip, compressEach

        var isExtraction: Bool { self == .extractHere || self == .extractToFolder }
        var verb: String { isExtraction ? "解压" : "压缩" }
    }

    static let currentVersion = 1
    var version = Self.currentVersion
    var id = UUID()
    var createdAt = Date()
    let operation: Operation
    let sources: [FinderFileRef]
    var conflictPolicy: ArchiveConflictPolicy = .skip
}

struct FinderTaskReceipt: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case queued, running, needsPassword, succeeded, failed, cancelled, expired, interrupted, appQuitting

        var isTerminal: Bool {
            switch self {
            case .queued, .running, .needsPassword: return false
            case .succeeded, .failed, .cancelled, .expired, .interrupted, .appQuitting: return true
            }
        }
    }

    var version = FinderTaskRequest.currentVersion
    let id: UUID
    var state: State
    var updatedAt = Date()
    var completedCount = 0
    var totalCount = 0
    var fraction: Double?
    var errorCode: String?
    var message: String?
    var outputNames: [String] = []
}

enum FinderTaskQueueError: LocalizedError {
    case unsafeLocation, invalidRequest, unsupportedVersion, tooLarge

    var errorDescription: String? {
        switch self {
        case .unsafeLocation: return "访达任务队列的位置或文件权限不安全"
        case .invalidRequest: return "访达任务请求无效"
        case .unsupportedVersion: return "访达任务协议版本不受支持"
        case .tooLarge: return "访达任务请求超出大小或项目数量限制"
        }
    }
}

struct FinderTaskQueue: Sendable {
    static let maxBytes = 256 * 1024
    static let maxSources = 100
    static let expiry: TimeInterval = 10 * 60
    static let retention: TimeInterval = 24 * 60 * 60

    let root: URL

    init(root: URL = SharedPaths.support.appendingPathComponent("finder-queue", isDirectory: true)) {
        self.root = root
    }

    var parent: URL { root.deletingLastPathComponent() }
    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var claimed: URL { root.appendingPathComponent("claimed", isDirectory: true) }
    var status: URL { root.appendingPathComponent("status", isDirectory: true) }

    @discardableResult
    func enqueue(_ request: FinderTaskRequest) throws -> Bool {
        try validate(request)
        let bytes = try JSONEncoder().encode(request)
        guard bytes.count <= Self.maxBytes else { throw FinderTaskQueueError.tooLarge }
        return try withLock {
            let destination = item(request.id, in: inbox)
            guard !exists(destination), !exists(item(request.id, in: claimed)),
                  try readReceipt(request.id)?.state.isTerminal != true else { return false }

            try writeReceipt(FinderTaskReceipt(id: request.id, state: .queued, totalCount: request.sources.count))
            do {
                try publish(bytes, at: destination, exclusive: true)
                return true
            } catch {
                try? FileManager.default.removeItem(at: item(request.id, in: status))
                throw error
            }
        }
    }

    func claimNext(now: Date = Date()) throws -> FinderTaskRequest? {
        try withLock {
            for file in try queueFiles(in: inbox) {
                guard let id = identifier(of: file) else { continue }
                let prior: FinderTaskReceipt?
                do {
                    prior = try readReceipt(id)
                } catch {
                    // 回执损坏时保守去重，避免重跑可能已写盘的任务。
                    try removeQueueEntry(file)
                    continue
                }
                if exists(item(id, in: claimed)) || prior?.state.isTerminal == true {
                    try removeQueueEntry(file)
                    continue
                }
                let request: FinderTaskRequest
                do {
                    request = try read(FinderTaskRequest.self, at: file)
                    try validate(request)
                    guard request.id == id else { throw FinderTaskQueueError.invalidRequest }
                } catch {
                    try writeReceipt(FinderTaskReceipt(id: id, state: .failed, updatedAt: now,
                                                       errorCode: "invalidRequest",
                                                       message: "访达任务文件无效，已拒绝"))
                    try removeQueueEntry(file)
                    continue
                }
                if now.timeIntervalSince(request.createdAt) >= Self.expiry {
                    try writeReceipt(FinderTaskReceipt(id: id, state: .expired, updatedAt: now,
                                                       totalCount: request.sources.count,
                                                       errorCode: "expired", message: "访达任务已过期"))
                    try removeQueueEntry(file)
                    continue
                }
                let destination = item(id, in: claimed)
                guard renamex_np(file.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw posixError()
                }
                return request
            }
            return nil
        }
    }

    func record(_ receipt: FinderTaskReceipt) throws {
        try withLock {
            guard try readReceipt(receipt.id)?.state.isTerminal != true else { return }
            try writeReceipt(receipt)
            let request = item(receipt.id, in: claimed)
            if receipt.state.isTerminal, exists(request) {
                try removeQueueEntry(request)
            }
        }
    }

    func receipt(for id: UUID) throws -> FinderTaskReceipt? {
        try withLock { try readReceipt(id) }
    }

    /// 调用方必须已取得执行者锁，避免把另一份正在执行的应用认作崩溃残留。
    func recover(now: Date = Date()) throws {
        try withLock {
            for file in try queueFiles(in: claimed) {
                guard let id = identifier(of: file) else { continue }
                if (try? readReceipt(id)?.state.isTerminal) != true {
                    let previous = try? readReceipt(id)
                    try writeReceipt(FinderTaskReceipt(id: id, state: .interrupted, updatedAt: now,
                                                       completedCount: previous?.completedCount ?? 0,
                                                       totalCount: previous?.totalCount ?? 0,
                                                       errorCode: "interrupted",
                                                       message: "rrzip 上次意外退出，请检查已生成的文件"))
                }
                try removeQueueEntry(file)
            }
            for file in try queueFiles(in: status) {
                guard let id = identifier(of: file), let previous = try? readReceipt(id),
                      now.timeIntervalSince(previous.updatedAt) >= Self.retention else { continue }
                try removeQueueEntry(file)
            }
        }
    }

    func acquireWorker() throws -> FileHandle? {
        try prepareDirectories()
        // 放在队列的上一级，重建队列目录时仍是同一把执行者锁。
        let path = parent.appendingPathComponent(".\(root.lastPathComponent).worker")
        let file = try openLock(at: path)
        if flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0 { return file }
        if errno == EWOULDBLOCK { return nil }
        throw posixError()
    }

    func openWatchDirectory(_ url: URL) throws -> Int32 {
        try prepareDirectories()
        let fd = open(url.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(fd, &info) == 0, ownedDirectory(info) else {
            close(fd)
            throw FinderTaskQueueError.unsafeLocation
        }
        return fd
    }

    func inboxIsCurrent(_ fd: Int32) -> Bool {
        var connected = stat()
        var current = stat()
        return fstat(fd, &connected) == 0 && lstat(inbox.path, &current) == 0 &&
            ownedDirectory(current) && connected.st_dev == current.st_dev && connected.st_ino == current.st_ino
    }

    private func withLock<T>(_ work: () throws -> T) throws -> T {
        try prepareDirectories()
        let lock = try openLock(at: root.appendingPathComponent(".lock"))
        defer { try? lock.close() }
        guard flock(lock.fileDescriptor, LOCK_EX) == 0 else { throw posixError() }
        return try work()
    }

    private func prepareDirectories() throws {
        try ensureDirectory(parent, parents: true)
        try ensureDirectory(root, parents: false)
        for directory in [inbox, claimed, status] { try ensureDirectory(directory, parents: false) }
    }

    private func ensureDirectory(_ url: URL, parents: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: parents,
                                                       attributes: [.posixPermissions: 0o700])
            } catch where exists(url) {
                // 另一个合作进程先建好了，下面仍然核验类型及属主。
            }
        }
        guard lstat(url.path, &info) == 0, ownedDirectory(info) else { throw FinderTaskQueueError.unsafeLocation }
    }

    private func ownedDirectory(_ info: stat) -> Bool {
        info.st_uid == getuid() && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && info.st_mode & 0o022 == 0
    }

    private func openLock(at url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        _ = try regularInfo(fd)
        return file
    }

    private func validate(_ request: FinderTaskRequest) throws {
        guard request.version == FinderTaskRequest.currentVersion else { throw FinderTaskQueueError.unsupportedVersion }
        guard request.sources.count <= Self.maxSources else { throw FinderTaskQueueError.tooLarge }
        guard !request.sources.isEmpty, request.sources.allSatisfy(\.isValid),
              request.conflictPolicy == .skip else { throw FinderTaskQueueError.invalidRequest }
    }

    private func writeReceipt(_ receipt: FinderTaskReceipt) throws {
        try publish(JSONEncoder().encode(receipt), at: item(receipt.id, in: status), exclusive: false)
    }

    private func readReceipt(_ id: UUID) throws -> FinderTaskReceipt? {
        let file = item(id, in: status)
        guard exists(file) else { return nil }
        let receipt = try read(FinderTaskReceipt.self, at: file)
        guard receipt.id == id, receipt.version == FinderTaskRequest.currentVersion else {
            throw FinderTaskQueueError.invalidRequest
        }
        return receipt
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let info = try regularInfo(fd)
        guard info.st_size <= Self.maxBytes else { throw FinderTaskQueueError.tooLarge }
        let data = try file.read(upToCount: Self.maxBytes + 1) ?? Data()
        guard data.count <= Self.maxBytes else { throw FinderTaskQueueError.tooLarge }
        return try JSONDecoder().decode(type, from: data)
    }

    private func regularInfo(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o022 == 0 else { throw FinderTaskQueueError.unsafeLocation }
        return info
    }

    private func publish(_ bytes: Data, at target: URL, exclusive: Bool) throws {
        guard bytes.count <= Self.maxBytes else { throw FinderTaskQueueError.tooLarge }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try file.write(contentsOf: bytes)
        try file.close()
        let result = exclusive
            ? renamex_np(temp.path, target.path, UInt32(RENAME_EXCL))
            : rename(temp.path, target.path)
        guard result == 0 else { throw posixError() }
    }

    private func queueFiles(in folder: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                              options: .skipsHiddenFiles)
        let dated: [(file: URL, date: Date)] = files.map { file in
            let values = try? file.resourceValues(forKeys: [.creationDateKey])
            return (file, values?.creationDate ?? .distantPast)
        }
        let sorted = dated.sorted { left, right in
            if left.date != right.date { return left.date < right.date }
            return left.file.lastPathComponent < right.file.lastPathComponent
        }
        return sorted.map(\.file)
    }

    private func item(_ id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func identifier(of url: URL) -> UUID? {
        guard url.pathExtension == "json" else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private func removeQueueEntry(_ url: URL) throws {
        if unlink(url.path) == 0 || errno == ENOENT { return }
        let error = posixError()
        // 伪装成 .json 的目录不是队列文件，绝不递归删除。
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { return }
        throw error
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
