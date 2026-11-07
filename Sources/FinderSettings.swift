// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  FinderSettings.swift
//  rrzip
//
//  访达右键菜单的动作清单与配置。
//  放在主 target 里是因为设置页要读写它，扩展只读——
//  两份结构体各写一遍迟早会对不上。
//

import Foundation

/// 主程序与访达扩展共用的落盘位置。
///
/// 沙盒扩展里 `FileManager.homeDirectoryForCurrentUser` 指向
/// `~/Library/Containers/<bundle-id>/Data`，读不到主程序写的配置。
/// 用 `getpwuid` 取真实 home（沙盒不拦截这个 C 接口），
/// 再靠扩展 entitlements 里的 temporary-exception 获得该目录的读写权。
enum SharedPaths {
    static var home: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/rrzip
    static var support: URL {
        home.appendingPathComponent("Library/Application Support/rrzip", isDirectory: true)
    }
}

/// 右键菜单里的动作。rawValue 同时是 finder.json 里开关键的取值。
enum FinderAction: String, CaseIterable, Codable, Sendable {
    case open
    case extractHere
    case extractToFolder
    case compressZip
    case compressSevenZip
    case compressEach

    var title: String {
        switch self {
        case .open: return "用 rrzip 打开"
        case .extractHere: return "解压到此处"
        case .extractToFolder: return "解压到「包名」文件夹"
        case .compressZip: return "压缩为 ZIP"
        case .compressSevenZip: return "压缩为 7Z"
        case .compressEach: return "分别压缩"
        }
    }

    var group: String {
        isExtract ? "解压" : "压缩"
    }

    /// 界面上「解压」这类动作要排在「压缩」前面
    var isExtract: Bool {
        switch self {
        case .open, .extractHere, .extractToFolder: return true
        case .compressZip, .compressSevenZip, .compressEach: return false
        }
    }
}

/// 扩展读的配置。主程序写，扩展只读。
/// ad-hoc 签名下 App Group 不生效（没有 Team ID），所以走共享文件；
/// 上了 Developer ID 再换成 UserDefaults(suiteName:)，这个结构不用动。
struct FinderSettings: Codable, Equatable, Sendable {
    enum ExtractStrategy: String, Codable, Sendable {
        /// 解到「包名」子目录，重名就「包名 2」
        case newFolder
        /// 解到压缩包所在目录
        case here
    }

    var secondLevel: Bool
    var enabled: [String]
    var extractStrategy: ExtractStrategy

    static let allActions = FinderAction.allCases.map(\.rawValue)

    init(secondLevel: Bool = true,
         enabled: [String] = FinderSettings.allActions,
         extractStrategy: ExtractStrategy = .newFolder) {
        self.secondLevel = secondLevel
        self.enabled = enabled
        self.extractStrategy = extractStrategy
    }

    // 配置里少一个键不应该让整份设置失效，逐项给默认值
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        secondLevel = try container.decodeIfPresent(Bool.self, forKey: .secondLevel) ?? true
        enabled = try container.decodeIfPresent([String].self, forKey: .enabled)
            ?? FinderSettings.allActions
        extractStrategy = try container.decodeIfPresent(ExtractStrategy.self, forKey: .extractStrategy)
            ?? .newFolder
    }

    static var fileURL: URL {
        SharedPaths.support.appendingPathComponent("finder.json")
    }

    static func load(from url: URL = FinderSettings.fileURL) -> FinderSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(FinderSettings.self, from: data)
        else { return FinderSettings() }
        return settings
    }

    func isEnabled(_ action: FinderAction) -> Bool {
        enabled.contains(action.rawValue)
    }

    /// 菜单项按设置过滤。全关掉就返回空，菜单不显示。
    func filtered(_ actions: [FinderAction]) -> [FinderAction] {
        actions.filter(isEnabled)
    }

    mutating func setEnabled(_ action: FinderAction, _ on: Bool) {
        if on {
            if !enabled.contains(action.rawValue) { enabled.append(action.rawValue) }
        } else {
            enabled.removeAll { $0 == action.rawValue }
        }
    }
}

// MARK: - 落盘

enum FinderSettingsStore {

    /// 原子写：同目录临时文件 + `rename(2)` 覆盖目标。
    ///
    /// 为什么不用 `FileManager.replaceItemAt`：它在目标不存在时的行为不跨版本一致，
    /// 失败只抛错、不写盘，而调用方又是 `try?`，于是「第一次保存」可能悄悄什么都没发生——
    /// 用户改完设置、重启访达，菜单还是旧的。`rename` 的语义是明确的：
    /// 目标存在就原子替换，不存在就原子创建，读者要么看到完整旧文件、要么看到完整新文件。
    ///
    /// 返回是否真的写成功。设置页据此提示，不再无条件显示「已保存」。
    @discardableResult
    static func save(_ settings: FinderSettings, to url: URL = FinderSettings.fileURL) -> Bool {
        let folder = url.deletingLastPathComponent()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return false }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return false
        }

        // 每次用独立临时名：连点开关时两次保存可能重叠，
        // 共用一个固定名字会互相截断；残留也靠 UUID 区分，便于失败时只删自己那份。
        let staging = folder.appendingPathComponent(".finder.json.\(UUID().uuidString).tmp")
        do {
            try data.write(to: staging, options: .atomic)
        } catch {
            return false
        }

        // rename 失败时目标文件保持原样（旧配置还在），临时文件不留在原地
        guard rename(staging.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
        return true
    }
}
