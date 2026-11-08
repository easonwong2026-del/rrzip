// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import QuickLookUI

/// 访达里按空格即可看到压缩包内容
@objc(PreviewProvider)
final class PreviewProvider: NSViewController, QLPreviewingController {

    private var tableView: NSTableView?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var rows: [(name: String, size: String)] = []

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
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        _ = view
        titleLabel?.stringValue = url.lastPathComponent
        subtitleLabel?.stringValue = "正在读取…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<[ArchiveEntry], Error>
            do {
                // 走统一入口：扩展里用进程内 libarchive，起不了子进程也能读
                outcome = .success(try ArchiveService.list(url, password: nil))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                self?.render(outcome)
                handler(nil)
            }
        }
    }

    private func render(_ outcome: Result<[ArchiveEntry], Error>) {
        switch outcome {
        case .success(let entries):
            rows = entries.prefix(300).map { ($0.name, $0.isDirectory ? "—" : $0.displaySize) }
            let suffix = entries.count > 300 ? "（仅显示前 300 项）" : ""
            subtitleLabel?.stringValue = entries.isEmpty
                ? "这个压缩包里没有项目"
                : "\(entries.count) 个项目 \(suffix)"
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
        let label = NSTextField(labelWithString: isName ? item.name : item.size)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = isName ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
