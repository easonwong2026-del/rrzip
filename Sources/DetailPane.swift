// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  右侧详情栏
//  拆自 ContentView.swift，成员全部是 extension，不持有状态。

import AppKit
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
// UNUserNotificationCenter 没标 Sendable，但它的方法本身就是线程安全的；
// 用 @preconcurrency 压掉严格并发下的误报，不绕过检查本身
@preconcurrency import UserNotifications

extension ContentView {
    var detailKind: FileKind {
        guard let ext = model.current?.archive.pathExtension.lowercased() else { return .archive }
        return FileKind(ext: ext)
    }

    var detailPane: some View {
        VStack(spacing: 0) {
            detailHeader
            infoCard
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            Hairline()
            PreviewPane(model: model)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    var detailHeader: some View {
        let kind = detailKind
        return VStack(spacing: 7) {
            KindBadge(kind: kind, side: 44, corner: 11)
            Text(model.current?.archive.lastPathComponent ?? "")
                .font(TypeScale.title)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
            HStack(spacing: 5) {
                TintPill(text: model.archiveFormatName, tint: kind.tint)
                if model.isEncrypted {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill").font(.system(size: 7.5, weight: .bold))
                        Text("已加密").font(.system(size: 9.5, weight: .semibold))
                    }
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            LinearGradient(colors: [kind.tint.opacity(0.07), kind.tint.opacity(0.015)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("大小", model.archiveSizeText)
            rowDivider
            infoRow("条目", "\(model.totalEntryCount)")
            rowDivider
            infoRow("加密", model.isEncrypted ? "是" : "否")
            rowDivider
            infoRow("修改", model.archiveModifiedText)
            rowDivider
            infoRow("识别", model.detectionSourceText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .cardSurface()
    }

    var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(height: 1)
            .padding(.leading, 2)
    }

    func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TypeScale.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(TypeScale.data())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4.5)
    }

    // MARK: 简化模式

    /// 简化模式：单栏列表 + 右侧浮层预览。
    /// 与完整模式共用同一个 model，所以目录层级、选中项、预览都不用搬。
}
