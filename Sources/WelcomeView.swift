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
    @State private var finderReady = false

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
        .frame(width: 660, height: 456)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            quickLookReady = Self.extensionInstalled("ArchivePreview.appex")
            finderReady = Self.extensionInstalled("ArchiveFinder.appex")
        }
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
                detail: "右键即可解压、压缩；同名文件不会覆盖"
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
                     ? "快速查看已内置：访达里选中压缩包按空格即可看条目"
                     : "快速查看扩展未找到：重新构建应用可恢复")
                    .font(TypeScale.bodySmall)
                Spacer(minLength: 6)
                Button("设置…") { openExtensionSettings() }
                    .controlSize(.small)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: finderReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(finderReady ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(finderReady
                         ? "访达右键已内置：右键任意文件出现「rrzip ▸」"
                         : "访达右键扩展未找到：重新构建应用可恢复")
                        .font(TypeScale.bodySmall)
                    Text("首次使用需在 登录项与扩展 → 访达扩展 里勾选 rrzip，然后重启访达")
                        .font(TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button("设置…") { openExtensionSettings() }
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

    private func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: 环境

    /// 只判断 appex 在不在包里，判断不了它有没有被勾选——macOS 没有公开接口
    static func extensionInstalled(_ name: String) -> Bool {
        guard let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent(name) else {
            return false
        }
        return FileManager.default.fileExists(atPath: appex.path)
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// 引导只看主次版本：2.8.0 → 2.8.1 这种补丁升级不该再弹一次
    static func minorVersion(_ raw: String) -> String {
        raw.split(separator: ".").prefix(2).joined(separator: ".")
    }
}
