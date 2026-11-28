// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Foundation

enum FileKind {
    case folder, archive, image, pdf, video, audio, code, text, disk, other

    init(_ entry: ArchiveEntry) {
        if entry.isDirectory { self = .folder; return }
        if entry.isArchive { self = .archive; return }
        self.init(ext: entry.ext)
    }

    init(ext: String) {
        // 归档名可能出现在详情头部、面包屑这些只有后缀的地方，先按归档判断
        if ArchiveKind.isArchive(ext: ext) { self = .archive; return }
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
