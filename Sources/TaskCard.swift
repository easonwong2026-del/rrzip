// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  长任务进度卡

import SwiftUI

struct TaskOverlay: View {
    let model: ArchiveModel
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: Space.s) {
            if model.jobVisible, let job = model.job {
                TaskCard(job: job) { model.cancelJob() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let job = model.finderJob {
                TaskCard(job: job) { model.cancelFinderTask?() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, bottomInset)
        .animation(.easeOut(duration: 0.18), value: model.job?.id)
        .animation(.easeOut(duration: 0.18), value: model.finderJob?.id)
    }
}

// MARK: - 任务进度卡

/// 长任务的进度卡。有真实百分比就画条，没有就转圈——
/// tar 不出进度，硬凑一个百分比比转圈更糟。
struct TaskCard: View {
    let job: TaskJob
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.brand)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(job.title)…")
                        .font(.system(size: 12, weight: .medium))
                    Text(job.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button("取消", action: onCancel)
                    .controlSize(.small)
                    .accessibilityLabel("取消任务 \(job.title)")
            }

            if job.queued > 0 {
                Text("还有 \(job.queued) 个排队")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let fraction = job.fraction {
                HStack(spacing: 8) {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(Palette.brand)
                        .accessibilityLabel("\(job.title)进度")
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.brand)
                    .accessibilityLabel("\(job.title)正在进行")
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
        .accessibilityElement(children: .contain)
    }
}

