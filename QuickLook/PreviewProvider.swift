// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import QuickLookUI

/// 访达里按空格即可看到压缩包内容
@objc(PreviewProvider)
final class PreviewProvider: NSViewController, QLPreviewingController {

    // Quick Look 传入 ObjC 回调。只把它传递到主线程，并始终在那里调用一次。
    private struct PreviewCompletion: @unchecked Sendable {
        let handler: (Error?) -> Void
        @MainActor func finish() { handler(nil) }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private var tableView: NSTableView?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private static let rowLimit = 300
    private var rows: [ArchiveEntry] = []
    private var currentFlag: CancellationFlag?
    private var symbols: [String: NSImage] = [:]

    deinit {
        currentFlag?.cancel()
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 500))
        view = container

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingMiddle
        container.addSubview(title)
        titleLabel = title

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)
        subtitleLabel = subtitle

        let table = NSTableView()
        table.headerView = nil
        table.rowSizeStyle = .small
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.width = 560
        let sizeColumn = NSTableColumn(identifier: .init("size"))
        sizeColumn.width = 90
        table.addTableColumn(nameColumn)
        table.addTableColumn(sizeColumn)
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        tableView = table
    }


    /// Quick Look 在显示窗口前调用。Apple 明确要求这里别阻塞主线程：
    /// 大归档列目录可能几十万条，同步跑会把整个预览卡住，所以派到后台队列，
    /// 结果回主线程再刷表格。
    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let completion = PreviewCompletion(handler: handler)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return completion.finish() }
            self.prepare(url, completion: completion)
        }
    }

    private func prepare(_ url: URL, completion: PreviewCompletion) {
        _ = view
        currentFlag?.cancel()
        let flag = CancellationFlag()
        currentFlag = flag

        titleLabel?.stringValue = url.lastPathComponent
        subtitleLabel?.stringValue = "正在读取…"
        rows = []
        tableView?.reloadData()

        let limit = Self.rowLimit
        Task { [weak self] in
            let outcome: Result<(summary: InProcessArchive.Summary, format: String?), Error> =
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Result {
                            // 扩展内存上限严苛：仅实例化前 300 项，超出只计数。
                            let summary = try InProcessArchive.listSummary(
                                url, passphrase: nil, limit: limit, isCancelled: { flag.isCancelled }
                            )
                            return (summary: summary, format: FormatDetector.detect(url)?.displayName)
                        }
                        continuation.resume(returning: result)
                    }
                }
            if !flag.isCancelled { self?.render(outcome) }
            completion.finish()
        }
    }

    static func subtitle(format: String?, totalCount: Int, totalBytes: Int64) -> String {
        var parts = [format ?? "归档", "共 \(totalCount) 个项目"]
        if totalBytes > 0 { parts.append("总大小 \(ByteFormatter.string(totalBytes))") }
        if totalCount > rowLimit { parts.append("仅显示前 \(rowLimit) 项") }
        return parts.joined(separator: " · ")
    }

    private func render(_ outcome: Result<(summary: InProcessArchive.Summary, format: String?), Error>) {
        switch outcome {
        case .success(let result):
            rows = result.summary.entries
            subtitleLabel?.stringValue = Self.subtitle(format: result.format, totalCount: result.summary.totalCount,
                                                        totalBytes: result.summary.totalBytes)
        case .failure(ArchiveError.needsPassword):
            rows = []
            subtitleLabel?.stringValue = "已加密：这里看不到内容，请在 rrzip 里输入密码"
        case .failure(ArchiveError.engineUnavailable):
            // 引擎缺失是环境问题，不是文件的问题，别让用户以为包坏了
            rows = []
            subtitleLabel?.stringValue = "预览面板缺少读取这个格式的引擎，请在 rrzip 里打开"
        case .failure(let error):
            rows = []
            subtitleLabel?.stringValue = "无法预览：\(error.localizedDescription)"
        }
        tableView?.reloadData()
    }
}

extension PreviewProvider: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let item = rows[row]
        let isName = tableColumn?.identifier.rawValue == "name"
        if isName {
            let cell = nameCell(in: tableView)
            let symbol = FileKind(item).symbol
            if symbols[symbol] == nil {
                symbols[symbol] = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            cell.imageView?.image = symbols[symbol]
            cell.textField?.stringValue = item.name
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("sizeCell")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            let created = NSTextField(labelWithString: "")
            created.identifier = identifier
            created.font = .systemFont(ofSize: 11.5)
            created.lineBreakMode = .byTruncatingMiddle
            label = created
        }
        label.stringValue = item.isDirectory ? "—" : item.displaySize
        label.textColor = .secondaryLabelColor
        return label
    }

    private func nameCell(in tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("nameCell")
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return reused }
        let cell = NSTableCellView()
        cell.identifier = id
        let icon = NSImageView()
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11.5)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
