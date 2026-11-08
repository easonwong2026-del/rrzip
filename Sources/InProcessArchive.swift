// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  InProcessArchive.swift
//  rrzip
//
//  进程内读归档，不启动任何子进程。
//
//  主程序一直用 `/usr/bin/tar`（bsdtar）列目录，够用也稳，但沙盒里的
//  Quick Look 扩展起不了它——`Process.run()` 直接返回 NSCocoaErrorDomain 4。
//  实测证据（扩展内）：能读文件头 504b0304、能写临时目录，只有 spawn 失败。
//
//  所以扩展改走系统自带的 libarchive：同一个 bsdtar 的底层库，进程内直接读，
//  不需要子进程、不需要额外权限。macOS SDK 只提供 libarchive.tbd 没有头文件，
//  这里按 ABI 声明用到的那几个入口。
//

import Foundation

enum InProcessArchive {

    // MARK: - libarchive C API

    private typealias Archive = OpaquePointer
    private typealias Entry = OpaquePointer

    /// 按 ABI 声明：macOS 只给了 libarchive.tbd，没有 archive.h
    private enum C {
        @_silgen_name("archive_read_new")
        static func readNew() -> OpaquePointer?
        @_silgen_name("archive_read_support_filter_all")
        static func supportFilterAll(_ a: OpaquePointer) -> Int32
        @_silgen_name("archive_read_support_format_all")
        static func supportFormatAll(_ a: OpaquePointer) -> Int32
        @_silgen_name("archive_read_add_passphrase")
        static func addPassphrase(_ a: OpaquePointer, _ passphrase: UnsafePointer<CChar>) -> Int32
        @_silgen_name("archive_read_open_filename")
        static func openFilename(_ a: OpaquePointer, _ path: UnsafePointer<CChar>, _ block: Int) -> Int32
        @_silgen_name("archive_read_next_header")
        static func nextHeader(_ a: OpaquePointer, _ entry: UnsafeMutablePointer<OpaquePointer?>) -> Int32
        @_silgen_name("archive_read_free")
        static func readFree(_ a: OpaquePointer) -> Int32
        @_silgen_name("archive_error_string")
        static func errorString(_ a: OpaquePointer) -> UnsafePointer<CChar>?
        @_silgen_name("archive_entry_pathname")
        static func pathname(_ e: OpaquePointer) -> UnsafePointer<CChar>?
        @_silgen_name("archive_entry_size")
        static func size(_ e: OpaquePointer) -> Int64
        @_silgen_name("archive_entry_filetype")
        static func filetype(_ e: OpaquePointer) -> UInt32
        @_silgen_name("archive_entry_mtime")
        static func mtime(_ e: OpaquePointer) -> Int64
    }

    // MARK: - 列目录

    /// 与 `Tar.list` 同语义同结构：失败抛 `ArchiveError`，加密抛 `.needsPassword`。
    static func list(_ url: URL, passphrase: String? = nil) throws -> [ArchiveEntry] {
        let reader = Reader()
        return try reader.list(url, passphrase: passphrase)
    }

    private struct Reader {
        private let ok: Int32 = 0
        private let eof: Int32 = 1
        private let warn: Int32 = -20
        private let ifdir: UInt32 = 0o040000

        func list(_ url: URL, passphrase: String?) throws -> [ArchiveEntry] {
            guard let handle = C.readNew() else {
                throw ArchiveError.tool("无法初始化 libarchive")
            }
            defer { _ = C.readFree(handle) }

            _ = C.supportFilterAll(handle)
            _ = C.supportFormatAll(handle)
            if let passphrase, !passphrase.isEmpty {
                _ = passphrase.withCString { C.addPassphrase(handle, $0) }
            }

            let opened = url.path.withCString { C.openFilename(handle, $0, 64 * 1024) }
            guard opened >= warn else {
                throw Self.mapError(handle, fallback: "无法读取 \(url.lastPathComponent)")
            }

            var entries: [ArchiveEntry] = []
            while true {
                var raw: OpaquePointer?
                let status = C.nextHeader(handle, &raw)
                if status == eof { break }
                if status < warn {
                    throw Self.mapError(handle, fallback: "无法读取 \(url.lastPathComponent)")
                }
                guard let entry = raw, let pathPointer = C.pathname(entry) else { continue }
                let path = String(cString: pathPointer)
                guard !path.isEmpty else { continue }
                let isDirectory = C.filetype(entry) == ifdir || path.hasSuffix("/")
                entries.append(ArchiveEntry(
                    path: path,
                    size: isDirectory ? 0 : C.size(entry),
                    modified: Self.dateText(C.mtime(entry)),
                    mode: isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
                ))
            }
            return entries
        }

        /// libarchive 的错误字符串只在这一层有意义；加密要单独认出来，
        /// 否则调用方只能看到一句泛泛的失败
        private static func mapError(_ handle: OpaquePointer, fallback: String) -> ArchiveError {
            let message = C.errorString(handle).map { String(cString: $0) } ?? fallback
            if Tar.looksEncrypted(message) { return .needsPassword }
            // 最常见的一条翻成人话，其余保持 libarchive 原文（比一句笼统的
            // 「请重新构建应用」有用得多）
            if message.lowercased().contains("unrecognized archive format") {
                return .tool("无法识别这个压缩包的格式（文件可能损坏，或者不是压缩包）")
            }
            return .tool(message)
        }

        private static func dateText(_ epoch: Int64) -> String {
            guard epoch > 0 else { return "—" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        }
    }
}
