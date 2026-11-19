// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Foundation
import UniformTypeIdentifiers

/// 拖出到访达的载荷。
///
/// 这里守的是一个很隐蔽的坑：访达向拖拽源要 `public.file-url`，
/// 如果只注册 `public.data`，它连「可以放」都不认，松手什么都不发生——
/// 用户看到的就是「拖出去没反应，也没解压」。
func runDragTests() {
    testDragOutProvider()
    testDragBackIntoOwnWindow()
}

private func testDragOutProvider() {
    print("拖拽 · 条目拖出到访达")
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("rrzip-drag-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let source = work.appendingPathComponent("说明.txt")
    try? Data("hello\n".utf8).write(to: source)

    // 1. 带内部载荷（普通文件）：两种类型都要在
    let withPayload = EntryDrag.makeProvider(name: "说明.txt",
                                             payload: Data("p".utf8)) { done in
        done(source, nil)
    }
    expect(withPayload.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           "访达请求的 public.file-url 必须能被满足")
    expect(withPayload.hasItemConformingToTypeIdentifier(rrzipEntryType.identifier),
           "暂存条用的内部类型仍在")
    expect(withPayload.suggestedName == "说明.txt", "建议名与列表一致",
           "实际 \(withPayload.suggestedName ?? "nil")")

    // 2. 没有内部载荷（目录）：只留文件表示
    let directory = EntryDrag.makeProvider(name: "照片", payload: nil) { done in
        done(nil, ArchiveError.tool("失败"))
    }
    expect(!directory.hasItemConformingToTypeIdentifier(rrzipEntryType.identifier),
           "目录不该带内部载荷")
    expect(directory.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           "目录也要能拖出")

    // 3. 真正走一次加载：能拿到文件，名字取自 suggestedName。
    //    注意：loadFileRepresentation 给的临时副本只在回调期间有效，
    //    出了回调就被系统删掉——内容和名字都必须在闭包里取。
    let box = ResultBox()
    withPayload.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, _ in
        box.set(url, contents: url.flatMap { FileManager.default.contents(atPath: $0.path) })
    }
    expect(waitUntil(5, { box.value != nil }), "拖拽承诺能解析出文件")
    expect(box.value?.lastPathComponent == "说明.txt", "落盘名字用建议名",
           "实际 \(box.value?.lastPathComponent ?? "nil")")
    expect(box.contents == Data("hello\n".utf8), "内容与源文件一致",
           "实际 \(box.contents.map { "\($0.count) 字节" } ?? "nil")")
}

/// 拖回自己窗口：文件与目录都不能被当成「外部文件」再打开一次。
///
/// 目录没有暂存载荷，只能靠独立的来源标记识别——只判断 rrzipEntryType 的话，
/// 目录会被漏掉，拖回窗口就开始解压然后报「不支持的格式」。
private func testDragBackIntoOwnWindow() {
    print("拖拽 · 拖回自身窗口不触发打开")

    let file = EntryDrag.makeProvider(name: "a.txt", payload: Data("p".utf8)) { done in
        done(nil, nil)
    }
    expect(EntryDrag.isInternal(file), "普通文件被识别为应用内拖拽")

    let folder = EntryDrag.makeProvider(name: "照片", payload: nil) { done in
        done(nil, nil)
    }
    expect(EntryDrag.isInternal(folder), "目录被识别为应用内拖拽")
    expect(!folder.hasItemConformingToTypeIdentifier(rrzipEntryType.identifier),
           "目录仍然不带暂存载荷")

    // 外部文件（访达拖进来的）不能被误判成内部拖拽
    let external = NSItemProvider(contentsOf: URL(fileURLWithPath: "/tmp")) ?? NSItemProvider()
    expect(!EntryDrag.isInternal(external), "外部拖入不被误判")
}

/// 跨线程交接用的小盒子：loadFileRepresentation 的回调不一定在主线程
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    private var storedContents: Data?
    var value: URL? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    var contents: Data? {
        lock.lock(); defer { lock.unlock() }
        return storedContents
    }
    func set(_ url: URL?, contents: Data?) {
        lock.lock(); defer { lock.unlock() }
        stored = url
        storedContents = contents
    }
}
