// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  长任务进度卡

import AppKit
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
// UNUserNotificationCenter 没标 Sendable，但它的方法本身就是线程安全的；
// 用 @preconcurrency 压掉严格并发下的误报，不绕过检查本身
@preconcurrency import UserNotifications

// MARK: - 任务进度卡

/// 长任务的进度卡。有真实百分比就画条，没有就转圈——
/// tar 不出进度，硬凑一个百分比比转圈更糟。
struct TaskCard: View {
    let task: TaskProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.brand)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(task.title)…")
                        .font(.system(size: 12, weight: .medium))
                    Text(task.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button("取消", action: onCancel)
                    .controlSize(.small)
            }

            if let fraction = task.fraction {
                HStack(spacing: 8) {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(Palette.brand)
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.brand)
            }
        }
        .padding(12)
        .frame(width: 330)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
    }
}

