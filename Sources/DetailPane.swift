// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  右侧详情栏
//  拆自 ContentView.swift，成员全部是 extension，不持有状态。

import SwiftUI

extension ContentView {
    var detailKind: FileKind {
        guard let ext = model.current?.archive.pathExtension.lowercased() else { return .archive }
        return FileKind(ext: ext)
    }

    var detailPane: some View {
        VStack(spacing: 0) {
            detailHeader
            archiveSummary
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
            Hairline()
            // 预览拿回原来被五条元信息占走的高度
            PreviewPane(model: model)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    var detailHeader: some View {
        let kind = detailKind
        return VStack(spacing: 6) {
            KindBadge(kind: kind, side: 38, corner: 10)
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
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [kind.tint.opacity(0.07), kind.tint.opacity(0.015)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    /// 常驻信息只留一行：大小 + 条目数。
    /// 修改时间与识别来源属于「要看的时候才看」，挂在提示里；
    /// 加密状态在头部已经有胶囊，这里不再重复一行「加密：否」。
    var archiveSummary: some View {
        HStack(spacing: 5) {
            Text(model.archiveSizeText)
                .monospacedDigit()
            Text("·")
                .foregroundStyle(.quaternary)
            Text("\(model.totalEntryCount) 项")
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(TypeScale.data(10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .cardSurface()
        .help("修改：\(model.archiveModifiedText)\n识别：\(model.detectionSourceText)")
    }

    // MARK: 简化模式

    /// 简化模式：单栏列表 + 右侧浮层预览。
    /// 与完整模式共用同一个 model，所以目录层级、选中项、预览都不用搬。
}
