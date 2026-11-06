// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import UniformTypeIdentifiers

/// 统一的拖拽载荷：给访达的是解出来的文件，给暂存区的是「包 + 包内路径」。
/// 条目拖出到访达与拖进暂存区共用这一份实现，避免两处走样。
enum EntryDrag {
    @MainActor
    static func provider(for entry: ArchiveEntry, model: ArchiveModel) -> NSItemProvider {
        let provider = NSItemProvider()

        if !entry.isDirectory, let archive = model.current?.archive {
            let payload = [archive.path, entry.path, String(entry.size)]
            let data = Data(payload.joined(separator: "\u{1F}").utf8)
            provider.registerDataRepresentation(
                forTypeIdentifier: rrzipEntryType.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
        }

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task { @MainActor in
                model.payloadURL(for: entry) { url in
                    if let url {
                        completion(url, false, nil)
                    } else {
                        completion(nil, false, ArchiveError.tool("导出 \(entry.name) 失败"))
                    }
                }
            }
            return nil
        }
        return provider
    }
}
