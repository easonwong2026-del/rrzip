// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import UniformTypeIdentifiers

/// 统一的拖拽载荷：给访达的是解出来的文件，给暂存区的是「包 + 包内路径」。
/// 条目拖出到访达与拖进暂存区共用这一份实现，避免两处走样。
enum EntryDrag {
    /// 装配载荷。解压这一步由 `loadFile` 注入，便于测试只验类型与命名。
    ///
    /// 类型注册是这里的坑：访达向拖拽源要的是 `public.file-url`，
    /// 只注册 `public.data` 的话它连「可以放」都不认，松手什么都不会发生
    /// （`NSItemProvider.hasItemConformingToTypeIdentifier("public.file-url")`
    /// 会是 false）。所以文件表示必须挂在 `public.file-url` 上。
    static func makeProvider(
        name: String,
        payload: Data?,
        loadFile: @escaping (@escaping (URL?, Error?) -> Void) -> Void
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        // 访达按这个名字落盘，和列表里看到的一致
        provider.suggestedName = name

        // 来源标记：文件和目录都带。窗口与首页靠它认出「这是自己拖出来的」，
        // 否则拖回自己会被当成外部文件打开（目录连暂存载荷都没有，只能靠这个标记）
        provider.registerDataRepresentation(
            forTypeIdentifier: rrzipDragMarkerType,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }

        if let payload {
            // 应用内（暂存条）只读这一份「包 + 包内路径」，不解压
            provider.registerDataRepresentation(
                forTypeIdentifier: rrzipEntryType.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(payload, nil)
                return nil
            }
        }

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            loadFile { url, error in
                if let url {
                    completion(url, false, nil)
                } else {
                    completion(nil, false, error ?? ArchiveError.tool("导出失败"))
                }
            }
            return nil
        }
        return provider
    }

    /// 这次拖拽是不是从本应用列表里发起的（文件与目录都算）
    static func isInternal(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(rrzipDragMarkerType)
    }

    @MainActor
    static func provider(for entry: ArchiveEntry, model: ArchiveModel) -> NSItemProvider {
        var payload: Data?
        if !entry.isDirectory, let archive = model.current?.archive {
            payload = Data([archive.path, entry.path, String(entry.size)]
                .joined(separator: "\u{1F}").utf8)
        }

        return makeProvider(name: entry.name, payload: payload) { done in
            Task { @MainActor in
                model.payloadURL(for: entry) { url in
                    if let url {
                        done(url, nil)
                    } else {
                        done(nil, ArchiveError.tool("导出 \(entry.name) 失败"))
                    }
                }
            }
        }
    }
}
