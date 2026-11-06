// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  HomeView.swift
//  rrzip
//
//  没有打开压缩包时的首页：打开 / 新建 / 最近打开 / 快速压缩。
//  一切入口都在这一屏，不需要先打开一个包才能找到功能。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var model: ArchiveModel

    @State private var quickTargeted = false
    @State private var quickResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxxl) {
                header
                actionCards
                HStack(alignment: .top, spacing: 26) {
                    recentSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                    quickSection
                        .frame(width: 250)
                }
                footer
            }
            .padding(.horizontal, 34)
            .padding(.top, 34)
            .padding(.bottom, 26)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            KindBadge(kind: .archive, side: 46, corner: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("rrzip")
                    .font(.system(size: 21, weight: .semibold))
                Text("macOS 原生压缩包工作台")
                    .font(TypeScale.bodySmall)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: 主操作

    private var actionCards: some View {
        HStack(spacing: 12) {
            actionCard(
                symbol: "folder",
                title: "打开压缩包",
                detail: "ZIP · RAR · 7Z · TAR · DMG…",
                prominent: true
            ) { model.openWithPanel() }
            actionCard(
                symbol: "archivebox",
                title: "新建压缩包",
                detail: "选文件，设格式与密码",
                prominent: false
            ) { model.createArchive() }
        }
    }

    private func actionCard(symbol: String, title: String, detail: String,
                            prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusThumb, style: .continuous)
                            .fill(prominent ? Color.white.opacity(0.18) : Color.primary.opacity(0.05))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(TypeScale.bodySmall.weight(.semibold))
                        .foregroundStyle(prominent ? Color.white : Color.primary)
                    Text(detail)
                        .font(TypeScale.caption)
                        .foregroundStyle(prominent ? Color.white.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 62)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .fill(prominent ? Palette.brand : Color.primary.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                            .strokeBorder(prominent ? .clear : Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(prominent ? "选择压缩包（⌘O）" : "新建压缩包（⌘N）")
    }

    // MARK: 最近打开

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("最近打开")
                    .font(TypeScale.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.recentArchives.isEmpty {
                    Button("清空") { model.clearRecentArchives() }
                        .buttonStyle(.link)
                        .font(TypeScale.caption)
                }
            }

            if model.recentArchives.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有打开过压缩包")
                        .font(TypeScale.bodySmall)
                        .foregroundStyle(.secondary)
                    Text("拖入一个包，或按 ⌘O 选择。")
                        .font(TypeScale.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.recentArchives) { item in
                        recentRow(item)
                    }
                }
            }
        }
    }

    private func recentRow(_ item: RecentArchive) -> some View {
        let available = item.exists
        return Button {
            guard available else { return }
            model.open(url: item.url)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: available ? "shippingbox" : "questionmark.folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(available ? Color.secondary : Color.secondary.opacity(0.45))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name)
                        .font(TypeScale.bodySmall)
                        .foregroundStyle(available ? Color.primary : Color.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !available {
                        Text("文件已移动")
                            .font(TypeScale.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 6)
                Text(Self.relativeTime(item.openedAt))
                    .font(TypeScale.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                    .fill(Color.primary.opacity(0.0001))
            )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(available ? item.path : "文件已移动：\(item.path)")
        .contextMenu {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            .disabled(!available)
            Button("从列表移除") { model.removeRecent(item) }
        }
    }

    // MARK: 快速压缩

    private var quickSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("快速压缩")
                .font(TypeScale.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Image(systemName: quickTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(quickTargeted ? Palette.brand : Color.secondary)
                Text(quickResult ?? "把文件拖进来")
                    .font(TypeScale.bodySmall)
                    .foregroundStyle(quickResult == nil ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                Text("在文件旁边生成 ZIP，\n重名自动加序号")
                    .font(TypeScale.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 108)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .fill(quickTargeted ? Palette.brand.opacity(0.06) : Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(quickTargeted ? Palette.brand.opacity(0.45) : Color.primary.opacity(0.14),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .onDrop(of: [.fileURL], isTargeted: $quickTargeted) { providers in
                handleQuickDrop(providers)
                return true
            }

            Text("要设密码或 7Z？用「新建压缩包」。")
                .font(TypeScale.micro)
                .foregroundStyle(.tertiary)
        }
    }

    private func handleQuickDrop(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { value, _ in
                        continuation.resume(returning: value)
                    }
                }
                if let url { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            // 拖进来的是压缩包就打开它，别把 zip 再压一层
            if urls.count == 1, case .open = OpenGate.decide(urls[0]) {
                model.open(url: urls[0])
                return
            }
            quickResult = "正在压缩 \(urls.count) 项…"
            model.quickCompress(urls)
            quickResult = "已生成 ZIP"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                quickResult = nil
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 14) {
            Button("使用指南") { openRemote("https://github.com/easonwong2026-del/rrzip#readme") }
                .buttonStyle(.link)
                .font(TypeScale.caption)
            Button("版本说明") { openReleaseNotes() }
                .buttonStyle(.link)
                .font(TypeScale.caption)
            Divider().frame(height: 11)
            Text("v\(Self.version)")
                .font(TypeScale.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("GPL-3.0")
                .font(TypeScale.caption)
                .foregroundStyle(.quaternary)
        }
    }

    private func openReleaseNotes() {
        let local = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/RELEASE_NOTES.md")
        if FileManager.default.fileExists(atPath: local.path) {
            NSWorkspace.shared.open(local)
        } else {
            openRemote("https://github.com/easonwong2026-del/rrzip/releases")
        }
    }

    private func openRemote(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
