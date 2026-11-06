// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  WelcomeView.swift
//  rrzip
//
//  首次启动的一屏说明。不搞多页向导，看完就走。
//

import AppKit
import SwiftUI

struct WelcomeView: View {
    /// 关掉窗口时回调：是否记住「不再显示」
    let onFinish: (Bool) -> Void

    @State private var dontShowAgain = true
    @State private var quickLookReady = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            capabilities
            Hairline()
            integration
            footer
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(width: 660, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { quickLookReady = Self.quickLookInstalled }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 13) {
            KindBadge(kind: .archive, side: 48, corner: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text("欢迎使用 rrzip")
                    .font(.system(size: 20, weight: .semibold))
                Text("macOS 原生压缩包工作台 · 全部本地运行，不联网")
                    .font(TypeScale.bodySmall)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(Self.version)")
                .font(TypeScale.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 三条能力

    private var capabilities: some View {
        HStack(spacing: 10) {
            capability(
                symbol: "shippingbox",
                title: "打开与浏览",
                detail: "拖进来或按 ⌘O；目录树、分栏、包内搜索都在"
            )
            capability(
                symbol: "eye",
                title: "直接预览",
                detail: "图片、PDF、文本、视频音频不用先解压"
            )
            capability(
                symbol: "cursorarrow.click.2",
                title: "访达右键",
                detail: "选中文件即可「用 rrzip 压缩 / 打开」"
            )
        }
    }

    private func capability(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.brand)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusThumb, style: .continuous)
                        .fill(Palette.brand.opacity(0.10))
                )
            Text(title)
                .font(TypeScale.bodySmall.weight(.semibold))
            Text(detail)
                .font(TypeScale.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }

    // MARK: 系统集成状态

    private var integration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统集成")
                .font(TypeScale.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: quickLookReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(quickLookReady ? Color.green : Color.orange)
                Text(quickLookReady
                     ? "快速查看扩展已内置：在访达选中压缩包按空格即可看条目"
                     : "快速查看扩展未找到：重新构建应用可恢复")
                    .font(TypeScale.bodySmall)
                Spacer(minLength: 6)
                Button("设置…") { openSettings("extensions") }
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("「用 rrzip 压缩 / 打开」已注册到访达服务；右键看不到时，去服务列表勾选一次")
                    .font(TypeScale.bodySmall)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("设置…") { openSettings("services") }
                    .controlSize(.small)
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("启动时不再显示", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)
                .font(TypeScale.caption)
            Spacer()
            Button("开始使用") { finish() }
                .buttonStyle(.borderedProminent)
                .tint(Palette.brand)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func finish() {
        onFinish(dontShowAgain)
    }

    private func openSettings(_ which: String) {
        let candidates = which == "extensions"
            ? ["x-apple.systempreferences:com.apple.ExtensionsPreferences",
               "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]
            : ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
               "x-apple.systempreferences:com.apple.ExtensionsPreferences"]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: 环境

    static var quickLookInstalled: Bool {
        guard let appex = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("ArchivePreview.appex") else { return false }
        return FileManager.default.fileExists(atPath: appex.path)
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
