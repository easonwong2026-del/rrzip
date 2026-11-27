// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import Observation
import SwiftUI

/// 一次处理多个压缩包：批量解压或批量校验。
/// 串行执行，避免同时开一堆 7zz 抢磁盘。
@MainActor
@Observable
final class BatchRunner {
    enum Mode: Sendable {
        case extract
        case verify

        var title: String { self == .extract ? "批量解压" : "批量校验" }
        var actionTitle: String { self == .extract ? "开始解压" : "开始校验" }
        var hint: String {
            self == .extract
                ? "每个包解到目标目录下的同名文件夹，不会互相覆盖"
                : "用 7-Zip 完整读一遍，检查压缩包是否损坏"
        }
    }

    struct Job: Identifiable {
        enum State {
            case pending, running, done, failed, skipped
        }

        let id = UUID()
        let url: URL
        var state: State = .pending
        var detail: String = ""
    }

    private(set) var mode: Mode
    private(set) var jobs: [Job]
    private(set) var running = false
    private(set) var cancelled = false
    var destination: URL?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeJobID: UUID?

    init(urls: [URL], mode: Mode) {
        self.mode = mode
        self.jobs = urls.map { Job(url: $0) }
        if mode == .extract {
            self.destination = Self.defaultDestination()
        }
#if DEBUG
        if let path = UserDefaults.standard.string(forKey: "rrzip.batchDest") {
            self.destination = URL(fileURLWithPath: path, isDirectory: true)
        }
#endif
    }

    var finishedCount: Int {
        jobs.filter { $0.state == .done || $0.state == .failed || $0.state == .skipped }.count
    }

    var failureCount: Int { jobs.filter { $0.state == .failed }.count }
    var skippedCount: Int { jobs.filter { $0.state == .skipped }.count }

    var canStart: Bool {
        guard !running, !jobs.isEmpty,
              FormalWriteLedger.shared.currentGate.acceptsWrites else { return false }
        if mode == .extract { return destination != nil }
        return true
    }

    func start() {
        guard canStart else { return }
        let ledger = FormalWriteLedger.shared
        let kind: FormalWrite.Kind = mode == .extract ? .batchExtract : .batchVerify
        guard let batchID = ledger.begin(kind, label: "\(jobs.count) 个压缩包", onCancel: { [weak self] in
            self?.cancel()
        }) else { return }

        running = true
        cancelled = false
        let mode = self.mode
        let destination = self.destination

        task = Task {
            defer {
                cancelled = Task.isCancelled
                running = false
                task = nil
                ledger.end(batchID)
            }
            for index in jobs.indices {
                if Task.isCancelled { break }
                let id = jobs[index].id
                let archive = jobs[index].url
                do {
                    try TaskRegistry.claim(id)
                    activeJobID = id
                    defer {
                        activeJobID = nil
                        TaskRegistry.release(id)
                    }
                    jobs[index].state = .running
                    jobs[index].detail = ""

                    let detail = try await Task.detached(priority: .userInitiated) {
                        try TaskRegistry.checkCancellation(id)
                        switch mode {
                        case .extract:
                            guard let destination else { throw ArchiveError.tool("缺少批量解压目标目录") }
                            return try Self.extract(archive, into: destination, jobID: id)
                        case .verify:
                            try ArchiveService.verify(archive, jobID: id)
                            return "完整"
                        }
                    }.value
                    if mode == .verify, Task.isCancelled { throw ArchiveError.cancelled }
                    jobs[index].state = .done
                    jobs[index].detail = detail
                } catch ArchiveError.cancelled {
                    jobs[index].state = .skipped
                    jobs[index].detail = "已取消"
                    break
                } catch ArchiveError.needsPassword {
                    jobs[index].state = .skipped
                    jobs[index].detail = "已加密，需要密码"
                } catch {
                    let message = error.localizedDescription
                    jobs[index].state = .failed
                    jobs[index].detail = message.split(separator: "\n").last.map(String.init) ?? message
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        if let activeJobID { TaskRegistry.cancel(activeJobID) }
    }

    nonisolated private static func extract(_ archive: URL, into root: URL, jobID: UUID) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = uniqueFolder(for: archive, in: root)
        // 只有这次亲手建成的目录才能清理，重名竞争时保留对方的文件。
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try ArchiveService.extract(archive, entries: [], to: folder, password: nil, jobID: jobID)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder.lastPathComponent
    }

    /// 切换解压 / 校验：只重置状态，不动文件列表
    func switchMode(to newMode: Mode) {
        guard !running, newMode != mode else { return }
        mode = newMode
        for index in jobs.indices {
            jobs[index].state = .pending
            jobs[index].detail = ""
        }
    }

    /// 目标目录下建一个不重名的文件夹，复用全局 UniquePath 命名规则
    nonisolated static func uniqueFolder(for archive: URL, in root: URL) -> URL {
        let base = archive.deletingPathExtension().lastPathComponent
        let target = root.appendingPathComponent(base.isEmpty ? "归档" : base, isDirectory: true)
        return UniquePath.directory(target)
    }

    private static func defaultDestination() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }
}

/// 批量面板
struct BatchSheet: View {
    @State private var runner: BatchRunner
    @Environment(\.dismiss) private var dismiss

    init(urls: [URL], mode: BatchRunner.Mode) {
        _runner = State(wrappedValue: BatchRunner(urls: urls, mode: mode))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 560, height: 430)
#if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "rrzip.batchAutoStart") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                runner.start()
            }
        }
#endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            KindBadge(kind: .archive, side: 26, corner: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(runner.mode.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(runner.mode.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { runner.mode },
                set: { runner.switchMode(to: $0) }
            )) {
                Text("解压").tag(BatchRunner.Mode.extract)
                Text("校验").tag(BatchRunner.Mode.verify)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Palette.brand)
            .frame(width: 120)
            .disabled(runner.running)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(runner.jobs) { job in
                    HStack(spacing: 8) {
                        stateIcon(job.state)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.url.lastPathComponent)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !job.detail.isEmpty {
                                Text(job.detail)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(ByteFormatter.string(fileSize(job.url)))
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    Divider().padding(.leading, 38)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if runner.mode == .extract {
                HStack(spacing: 8) {
                    Text("解压到")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(runner.destination?.path ?? "未选择")
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(runner.destination == nil ? .tertiary : .primary)
                    Spacer()
                    Button("选择…") { pickDestination() }
                        .controlSize(.small)
                        .disabled(runner.running)
                }
            }

            HStack(spacing: 8) {
                if runner.running {
                    ProgressView(value: Double(runner.finishedCount), total: Double(max(1, runner.jobs.count)))
                        .frame(width: 150)
                    Text("\(runner.finishedCount)/\(runner.jobs.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if runner.finishedCount > 0 {
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(runner.failureCount > 0 ? Color.red : Color.secondary)
                }

                Spacer()

                if runner.running {
                    Button("取消") { runner.cancel() }
                        .controlSize(.small)
                } else {
                    Button("关闭") { dismiss() }
                        .controlSize(.small)
                    Button(runner.finishedCount > 0 ? "再跑一次" : runner.mode.actionTitle) {
                        runner.start()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.brand)
                    .disabled(!runner.canStart)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
    }

    private var summary: String {
        var parts = ["完成 \(runner.jobs.count - runner.failureCount - runner.skippedCount) 个"]
        if runner.failureCount > 0 { parts.append("失败 \(runner.failureCount)") }
        if runner.skippedCount > 0 { parts.append("跳过 \(runner.skippedCount)") }
        return parts.joined(separator: " · ")
    }

    private func stateIcon(_ state: BatchRunner.Job.State) -> some View {
        Group {
            switch state {
            case .pending:
                Image(systemName: "clock")
                    .foregroundStyle(.tertiary)
            case .running:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .skipped:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12))
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择解压目标目录"
        panel.prompt = "选择"
        guard panel.runModal() == .OK else { return }
        runner.destination = panel.url
    }
}
