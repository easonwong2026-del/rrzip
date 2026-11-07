// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  ExtractDestination.swift
//  rrzip
//
//  「解压位置」这项设置的真实解析。
//
//  只做一件事：把 UserDefaults 里的字符串翻译成「每次询问」或「这个目录」。
//  规则简单，但错一次就是丢用户的选择：路径失效时绝不能悄悄换成下载目录，
//  也不能当作「用户没设过」直接弹面板而不解释。
//

import Foundation

enum ExtractDestinationSetting {

    /// UserDefaults 键名。与旧版本一致，不做迁移。
    static let defaultsKey = "rrzip.extractDestination"

    enum Failure: String, Equatable, Sendable {
        /// 目录被删掉或移到别处
        case missing
        /// 路径还在，但已经不是目录（被同名文件占了）
        case notDirectory
        /// 存在但没有写权限：权限变更、挂载卷只读
        case denied

        var text: String {
            switch self {
            case .missing: return "目录不存在"
            case .notDirectory: return "路径已不是文件夹"
            case .denied: return "没有写入权限"
            }
        }
    }

    enum Resolution: Equatable, Sendable {
        /// 每次询问（面板）
        case ask
        /// 固定目录，已验证可用
        case fixed(URL)
        /// 用户设过固定目录，但现在用不了
        case invalid(path: String, failure: Failure)

        var url: URL? {
            if case .fixed(let url) = self { return url }
            return nil
        }

        var problem: String? {
            guard case .invalid(_, let failure) = self else { return nil }
            return "原定的解压目录不可用（\(failure.text)），请重新选择"
        }
    }

    /// 文件系统探测。测试里换成假实现就能覆盖「权限被收回」这类不好造的场景，
    /// 但默认路径仍然走真实文件系统——测试不该只测替身。
    struct Probe: Sendable {
        var isDirectory: @Sendable (String) -> Bool
        var isWritable: @Sendable (String) -> Bool

        static let live = Probe(
            isDirectory: { path in
                var flag: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &flag)
                return exists && flag.boolValue
            },
            isWritable: { path in
                FileManager.default.isWritableFile(atPath: path)
            }
        )
    }

    /// 空串（含只有空白）= 每次询问。这个约定旧版本就在用，保持不动。
    static func resolve(_ raw: String, probe: Probe = .live) -> Resolution {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return .ask }
        guard probe.isDirectory(path) else {
            // 区分「没了」和「被文件占了」：前者多半是用户自己删的，后者更像误操作
            let exists = FileManager.default.fileExists(atPath: path)
            return .invalid(path: path, failure: exists ? .notDirectory : .missing)
        }
        guard probe.isWritable(path) else { return .invalid(path: path, failure: .denied) }
        return .fixed(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// 写回设置。空串表示「每次询问」，与读取约定一致。
    static func store(_ path: String?) -> String {
        guard let path else { return "" }
        return path.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
