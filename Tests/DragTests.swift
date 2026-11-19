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
    testDirectoryExport()
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

/// 目录拖出：必须连后代一起导出。
///
/// 界面里的目录有两种：归档里真有的目录记录（显式），以及按文件路径推导出来的
/// （隐式）。隐式目录在 `entries` 里没有自己那一条，只解 `[entry.path]` 会拿到
/// 0 个文件——访达里就是「拖出去没反应」。
func testDirectoryExport() {
    print("拖拽 · 目录导出")
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("rrzip-dir-\(UUID().uuidString)", isDirectory: true)
    let src = work.appendingPathComponent("src", isDirectory: true)
    try? FileManager.default.createDirectory(at: src.appendingPathComponent("photos/nested"),
                                             withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: src.appendingPathComponent("empty"),
                                             withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    try? Data("A".utf8).write(to: src.appendingPathComponent("photos/a.jpg"))
    try? Data("B".utf8).write(to: src.appendingPathComponent("photos/b.jpg"))
    try? Data("C".utf8).write(to: src.appendingPathComponent("photos/nested/c.txt"))

    // 1. 隐式目录的 zip：只有文件记录，没有 photos/ 这一条
    let implicitZip = work.appendingPathComponent("implicit.zip")
    runTool("/usr/bin/zip", ["-X", "-q", implicitZip.path,
                             "photos/a.jpg", "photos/b.jpg", "photos/nested/c.txt"], cwd: src)

    // 2. 显式目录的 zip：带 photos/ 与空目录 empty/
    let explicitZip = work.appendingPathComponent("explicit.zip")
    runTool("/usr/bin/zip", ["-X", "-q", "-r", explicitZip.path, "photos", "empty"], cwd: src)

    expectDirectoryExport(implicitZip, label: "隐式目录 zip", expectsExplicitEntry: false)
    expectDirectoryExport(explicitZip, label: "显式目录 zip", expectsExplicitEntry: true)

    // 3. 显式目录的 7z（引擎不在就跳过，不让它把整套测试带红）
    let sevenZip = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Assets/7zz")
    if FileManager.default.isExecutableFile(atPath: sevenZip.path) {
        let explicit7z = work.appendingPathComponent("explicit.7z")
        runTool(sevenZip.path, ["a", "-t7z", "-y", explicit7z.path, "photos", "empty"], cwd: src)
        expectDirectoryExport(explicit7z, label: "显式目录 7z", expectsExplicitEntry: true)
    } else {
        print("  · 跳过 7z：Assets/7zz 不存在")
    }
}

private func expectDirectoryExport(_ archive: URL, label: String, expectsExplicitEntry: Bool) {
    MainActor.assumeIsolated {
    let model = ArchiveModel()
    model.open(url: archive)
    guard waitUntil(20, { model.current != nil }), let frame = model.current else {
        expect(false, "\(label) 没打开")
        return
    }

    let hasExplicit = frame.entries.contains { $0.path == "photos/" }
    expect(hasExplicit == expectsExplicitEntry, "\(label) 目录记录符合预期",
           "实际 explicit=\(hasExplicit)")

    guard let dir = model.entries(at: "").first(where: { $0.name == "photos" && $0.isDirectory }) else {
        expect(false, "\(label) 列表里没有 photos 目录")
        return
    }
    let paths = ArchiveModel.exportPaths(for: dir, in: frame.entries)
    expect(paths.count >= 4, "\(label) 目录导出包含后代", "实际 \(paths.count) 条")

    var result: URL?
    var done = false
    model.payloadURL(for: dir) { url in
        result = url
        done = true
    }
    expect(waitUntil(60, { done }), "\(label) 导出完成")
    guard let exported = result else {
        expect(false, "\(label) 导出失败（返回 nil）")
        return
    }
    let fm = FileManager.default
    expect(fm.fileExists(atPath: exported.appendingPathComponent("a.jpg").path),
           "\(label) 后代文件已导出")
    expect(fm.fileExists(atPath: exported.appendingPathComponent("nested/c.txt").path),
           "\(label) 子目录已重建")
    let text = try? String(contentsOf: exported.appendingPathComponent("nested/c.txt"),
                           encoding: .utf8)
    expect(text == "C", "\(label) 内容正确", "实际 \(text ?? "nil")")

    if expectsExplicitEntry {
        guard let empty = model.entries(at: "").first(where: { $0.name == "empty" && $0.isDirectory }) else {
            expect(false, "\(label) 列表里没有 empty 目录")
            return
        }
        var emptyURL: URL?
        var emptyDone = false
        model.payloadURL(for: empty) { url in
            emptyURL = url
            emptyDone = true
        }
        expect(waitUntil(30, { emptyDone }), "\(label) 空目录导出完成")
        expect(emptyURL != nil, "\(label) 显式空目录也能导出")
    }
    }
}

@discardableResult
private func runTool(_ path: String, _ args: [String], cwd: URL) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.currentDirectoryURL = cwd
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return -1
    }
    return process.terminationStatus
}
