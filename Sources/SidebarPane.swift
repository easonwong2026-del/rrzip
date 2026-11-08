// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  左侧目录树
//  拆自 ContentView.swift，成员全部是 extension，不持有状态。

import AppKit
import SwiftUI

extension ContentView {
    var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("目录")
                    .font(TypeScale.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.folderTree.count > 0 {
                    Text("\(model.folderTree.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    SidebarRow(
                        title: model.current?.archive.deletingPathExtension().lastPathComponent ?? "根目录",
                        kind: .archive,
                        isSelected: model.current?.prefix.isEmpty == true
                    ) {
                        model.jump(to: "")
                    }

                    OutlineGroup(model.folderTree, children: \.optionalChildren) { node in
                        SidebarRow(
                            title: node.name,
                            kind: .folder,
                            isSelected: model.current?.prefix == node.path
                        ) {
                            model.jump(to: node.path)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    // MARK: 详情

}

// MARK: - 侧栏行

struct SidebarRow: View {
    let title: String
    let kind: FileKind
    let isSelected: Bool
    let action: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                KindBadge(kind: kind, side: 16, corner: 4)
                Text(title)
                    .font(TypeScale.bodySmall.weight(isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected
                          ? Palette.selectionFill
                          : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}
