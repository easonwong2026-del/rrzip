// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  CreateArchiveSheet.swift
//  rrzip
//
//  「创建压缩包」参数面板。选完文件后弹出，确认后由 Model 选落点并写盘。
//  之前是 NSAlert + 手搓 NSPopUpButton，样式和主界面脱节，也不方便加压缩级别。
//

import SwiftUI

struct CreateArchiveSheet: View {
    let itemCount: Int
    let onConfirm: (CreateOptions) -> Void
    let onCancel: () -> Void

    @State private var format: CreateFormat
    @State private var level: CompressLevel = .normal
    @State private var encrypted = false
    @State private var password = ""
    @State private var volume: CreateVolume = .none

    init(itemCount: Int,
         onConfirm: @escaping (CreateOptions) -> Void,
         onCancel: @escaping () -> Void) {
        self.itemCount = itemCount
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        let preferred = UserDefaults.standard.string(forKey: "rrzip.defaultCreateFormat")
            .flatMap(CreateFormat.init(rawValue:)) ?? .zip
        _format = State(initialValue: preferred)
    }

    /// tar / tgz 没有加密与分卷的概念，相关控件直接禁用
    private var plain: Bool { format == .tar || format == .tgz }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 420)
        .background(Palette.window)
    }

    private var header: some View {
        HStack(spacing: 12) {
            KindBadge(kind: .archive, side: 40, corner: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("创建压缩包")
                    .font(.system(size: 14, weight: .semibold))
                Text("共 \(itemCount) 个项目")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("格式") {
                Picker("", selection: $format) {
                    ForEach(CreateFormat.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

            row("压缩级别") {
                Picker("", selection: $level) {
                    ForEach(CompressLevel.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .disabled(plain)
            }

            row("加密") {
                HStack(spacing: 8) {
                    Toggle("", isOn: $encrypted)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!encrypted)
                }
                .disabled(plain)
            }

            row("分卷") {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { volume != .none },
                        set: { volume = $0 ? .g1 : .none }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                    Picker("", selection: $volume) {
                        ForEach(CreateVolume.allCases.filter { $0 != .none }) {
                            Text($0.title).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .disabled(volume == .none)
                }
                .disabled(plain)
            }

            if plain {
                Text("tar / tgz 不支持加密与分卷，已停用。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("取消") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("开始压缩") {
                var options = CreateOptions()
                options.format = format
                options.level = level
                options.password = encrypted ? password : ""
                options.volume = volume
                onConfirm(options)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(Palette.brand)
            .disabled(encrypted && password.isEmpty)
        }
        .padding(18)
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
