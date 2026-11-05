// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import SwiftUI

/// 统一的配色：品牌紫 + 按文件类型区分的色板。
/// 深色模式下提高底色透明度，保证图标块在暗背景上仍然分得清。
enum Palette {
    /// 品牌色：选中、强调、徽标统一用它
    static let brand = Color(red: 0.45, green: 0.34, blue: 0.94)
}

enum FileKind {
    case folder, archive, image, pdf, video, audio, code, text, disk, other

    init(_ entry: ArchiveEntry) {
        if entry.isDirectory { self = .folder; return }
        if entry.isArchive { self = .archive; return }
        self.init(ext: entry.ext)
    }

    init(ext: String) {
        switch ext {
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp", "raw", "svg":
            self = .image
        case "pdf":
            self = .pdf
        case "mp4", "mov", "m4v", "mkv", "avi", "mpg", "mpeg", "webm":
            self = .video
        case "mp3", "flac", "wav", "m4a", "aac", "ogg", "aiff":
            self = .audio
        case "swift", "js", "ts", "py", "rb", "go", "rs", "java", "c", "h", "cpp", "hpp",
             "m", "mm", "cs", "php", "sh", "zsh", "bash", "json", "xml", "yml", "yaml",
             "toml", "html", "css", "scss", "sql", "kt", "kts":
            self = .code
        case "txt", "md", "rtf", "log", "csv", "tsv", "ini", "conf", "plist", "doc", "docx", "xls", "xlsx", "ppt", "pptx":
            self = .text
        case "dmg", "iso", "vhd", "vhdx", "vdi", "vmdk", "qcow2", "img", "wim":
            self = .disk
        default:
            self = .other
        }
    }

    /// 主色。浅色模式下饱和一些，深色模式下提亮一点，避免发暗。
    var tint: Color {
        switch self {
        case .folder: return Color(red: 0.19, green: 0.48, blue: 0.96)
        case .archive: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .image: return Color(red: 0.98, green: 0.57, blue: 0.18)
        case .pdf: return Color(red: 0.93, green: 0.29, blue: 0.32)
        case .video: return Color(red: 0.93, green: 0.34, blue: 0.62)
        case .audio: return Color(red: 0.10, green: 0.68, blue: 0.66)
        case .code: return Color(red: 0.18, green: 0.67, blue: 0.40)
        case .text: return Color(red: 0.40, green: 0.49, blue: 0.62)
        case .disk: return Color(red: 0.36, green: 0.43, blue: 0.80)
        case .other: return Color(red: 0.55, green: 0.57, blue: 0.61)
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .archive: return "shippingbox.fill"
        case .image: return "photo.fill"
        case .pdf: return "doc.text.fill"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext.fill"
        case .disk: return "externaldrive.fill"
        case .other: return "doc.fill"
        }
    }
}

/// 彩色图标徽标：圆角底 + 类型符号。列表、网格、侧栏、Mini 共用。
struct KindBadge: View {
    let kind: FileKind
    var side: CGFloat = 20
    var corner: CGFloat? = nil
    @Environment(\.colorScheme) private var scheme

    private var radius: CGFloat { corner ?? max(4, side * 0.26) }
    private var fillOpacity: Double { scheme == .dark ? 0.24 : 0.14 }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(kind.tint.opacity(fillOpacity))
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: side * 0.54, weight: .medium))
                    .foregroundStyle(kind.tint)
            )
    }
}

/// 小胶囊标签，例如「ZIP 压缩包」「嵌套」
struct TintPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}
