// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  InProcessArchive.swift
//  rrzip
//
//  进程内读归档，不启动任何子进程。
//
//  主程序与 Quick Look 扩展共用系统 libarchive，密码通过内存传入。
//  macOS SDK 未提供头文件，这里按 ABI 声明必要的入口。
//

import Darwin
import Foundation

enum InProcessArchive {

    // MARK: - libarchive C API

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
        static func filetype(_ e: OpaquePointer) -> mode_t
        @_silgen_name("archive_entry_strmode")
        static func strmode(_ e: OpaquePointer) -> UnsafePointer<CChar>?
        @_silgen_name("archive_entry_symlink")
        static func symlink(_ e: OpaquePointer) -> UnsafePointer<CChar>?
        @_silgen_name("archive_entry_mtime")
        static func mtime(_ e: OpaquePointer) -> Int64
        @_silgen_name("archive_entry_mtime_nsec")
        static func mtimeNanos(_ e: OpaquePointer) -> Int
        @_silgen_name("archive_entry_mtime_is_set")
        static func hasMtime(_ e: OpaquePointer) -> Int32
        @_silgen_name("archive_entry_is_encrypted")
        static func isEncrypted(_ e: OpaquePointer) -> Int32
        @_silgen_name("archive_read_data")
        static func readData(_ a: OpaquePointer, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int
    }

    // MARK: - 列目录

    /// 与 `Tar.list` 同语义同结构：失败抛 `ArchiveError`，加密抛 `.needsPassword`。
    static func list(_ url: URL, passphrase: String? = nil,
                     isCancelled: (() -> Bool)? = nil) throws -> [ArchiveEntry] {
        try Reader().listSummary(url, passphrase: passphrase, limit: nil, isCancelled: isCancelled).entries
    }

    /// 流式摘要列目录：最多仅实例化前 `limit` 条 `ArchiveEntry`，超出部分只累加 `totalCount`，
    /// 避免 Quick Look 扩展在超大压缩包下因全量分配触发 Jetsam OOM。
    static func listSummary(
        _ url: URL,
        passphrase: String? = nil,
        limit: Int = 300,
        isCancelled: (() -> Bool)? = nil
    ) throws -> (entries: [ArchiveEntry], totalCount: Int) {
        let reader = Reader()
        return try reader.listSummary(url, passphrase: passphrase, limit: limit, isCancelled: isCancelled)
    }

    private struct Reader {
        private let ok: Int32 = 0
        private let eof: Int32 = 1
        private let retry: Int32 = -10
        private let warn: Int32 = -20

        func listSummary(
            _ url: URL,
            passphrase: String?,
            limit: Int?,
            isCancelled: (() -> Bool)?
        ) throws -> (entries: [ArchiveEntry], totalCount: Int) {
            guard let handle = C.readNew() else {
                throw ArchiveError.tool("无法初始化 libarchive")
            }
            defer { _ = C.readFree(handle) }

            _ = C.supportFilterAll(handle)
            _ = C.supportFormatAll(handle)
            if let passphrase, !passphrase.isEmpty {
                let status = passphrase.withCString { C.addPassphrase(handle, $0) }
                guard status == ok else { throw Self.mapError(handle, fallback: "无法设置归档密码") }
            }

            let opened = url.path.withCString { C.openFilename(handle, $0, 64 * 1024) }
            guard opened >= warn else {
                let message = C.errorString(handle).map { String(cString: $0) }
                // 打不开文件时诊断会回显路径，文件名里的“encrypted”等不是密码提示。
                if let message, message.hasPrefix("Failed to open") { throw ArchiveError.tool(message) }
                throw Self.mapError(handle, fallback: "无法读取归档")
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"

            var entries: [ArchiveEntry] = []
            if let limit { entries.reserveCapacity(max(0, min(limit, 512))) }
            var totalCount = 0

            while true {
                if isCancelled?() == true { throw ArchiveError.cancelled }
                var raw: OpaquePointer?
                let status = C.nextHeader(handle, &raw)
                if status == eof { break }
                if status == retry { continue }
                if status < warn {
                    throw Self.mapError(handle, fallback: "无法读取归档")
                }
                guard let entry = raw, let pathPointer = C.pathname(entry) else { continue }
                guard pathPointer.pointee != 0 else { continue }

                // ZIP 等格式的文件名可在未解密时读取。读一个字节触发密码检查，
                // 避免把「目录可读」当成「密码正确」，也无需为列目录解压整份文件。
                if C.isEncrypted(entry) != 0 {
                    guard let passphrase, !passphrase.isEmpty else { throw ArchiveError.needsPassword }
                    var byte: UInt8 = 0
                    if C.readData(handle, &byte, 1) < 0 {
                        throw Self.mapError(handle, fallback: "无法读取加密条目")
                    }
                }
                totalCount += 1
                if let limit, entries.count >= limit { continue }
                let path = String(cString: pathPointer)
                let isDirectory = (C.filetype(entry) & S_IFMT) == S_IFDIR || path.hasSuffix("/")
                let modifiedDate = C.hasMtime(entry) != 0
                    ? Date(timeIntervalSince1970: Double(C.mtime(entry)) + Double(C.mtimeNanos(entry)) / 1e9) : nil
                let mode = C.strmode(entry).map { String(cString: $0).trimmingCharacters(in: .whitespaces) }
                entries.append(ArchiveEntry(
                    path: path,
                    size: isDirectory ? 0 : C.size(entry),
                    modified: modifiedDate.map { formatter.string(from: $0) } ?? "—",
                    mode: mode ?? "----------",
                    modifiedDate: modifiedDate,
                    symlinkTarget: C.symlink(entry).map { String(cString: $0) }
                ))
            }
            return (entries, totalCount)
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

    }
}
