// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  面包屑、状态条、提示条、拖放遮罩
//  拆自 ContentView.swift，成员全部是 extension，不持有状态。

import SwiftUI

extension ContentView {
    // MARK: 一次性提示

    /// 不与 alert 争焦点的轻提示：贴在状态栏上方，3 秒后自动消失。
    /// 只做「告知」，不带按钮——要用户做决定的场景一律走 alert。
    @ViewBuilder
    var noticeBar: some View {
        if let notice = model.notice {
            Text(notice)
                .font(TypeScale.bodySmall)
                .foregroundStyle(.primary)
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.m)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.bottom, Metrics.statusHeight + Space.l)
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: 拖入提示

    @ViewBuilder
    var dropOverlay: some View {
        if isDropTarget {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.brand.opacity(0.05))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.brand.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("松开即可打开")
                        .font(TypeScale.bodySmall.weight(.medium))
                }
                .foregroundStyle(Palette.brand)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(8)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: 工具栏

    var breadcrumbBar: some View {
        HStack(spacing: 4) {
            if model.trail.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Text("未打开归档")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            } else if model.isSearching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                    Text("搜索「\(model.searchText)」")
                        .font(TypeScale.bodySmall.weight(.medium))
                    Text("· \(model.displayEntries.count) 个结果")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            } else {
                if model.canGoBack {
                    Button {
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("返回上一级（⌘[）")
                    .padding(.trailing, 2)
                }

                ForEach(Array(model.trail.enumerated()), id: \.element.id) { index, frame in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                    crumb(index: index, frame: frame)
                }
            }

            Spacer(minLength: 8)

            if let current = model.current {
                Text(current.archive.deletingLastPathComponent().path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(current.archive.path)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.breadcrumbHeight)
        .background(.bar.opacity(0.6))
    }

    func crumb(index: Int, frame: ArchiveModel.Frame) -> some View {
        let isLast = index == model.trail.count - 1
        return Button {
            model.popTo(index)
        } label: {
            HStack(spacing: 5) {
                KindBadge(kind: frame.prefix.isEmpty ? .archive : .folder, side: 15, corner: 4)
                Text(frame.title)
                    .font(TypeScale.bodySmall.weight(isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isLast ? Color.primary.opacity(0.055) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(frame.title)
    }

    // MARK: 目录树

    var statusBar: some View {
        HStack(spacing: 7) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Palette.brand)
            } else {
                Circle()
                    .fill(Palette.brand)
                    .frame(width: 5, height: 5)
            }

            Text(model.status)
                .font(TypeScale.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // 结果数在面包屑、已选数在选中操作条，各自只出现一次；
            // 状态栏只留「这个包有多大」这类没有别处可看的信息
            if !model.archiveSizeText.isEmpty {
                statusItem(model.archiveSizeText, mono: true)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.statusHeight)
        .background(Palette.chrome)
    }

    func statusItem(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? TypeScale.data(10.5) : TypeScale.caption)
            .foregroundStyle(.tertiary)
    }
}
