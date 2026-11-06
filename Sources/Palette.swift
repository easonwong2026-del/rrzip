// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import SwiftUI

/// 统一的配色：品牌紫 + 按文件类型区分的色板。
/// 品牌色只用在「主操作 / 选中 / 强调」，其余一律走系统语义色，
/// 否则整条工具栏都是紫的，层次会糊在一起。
extension AppearanceMode {
    /// 弹窗、小窗这些独立窗口读不到主窗口的 preferredColorScheme，只能自己读一次
    static var stored: AppearanceMode {
        UserDefaults.standard.string(forKey: "rrzip.appearance")
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}

enum Palette {
    /// 品牌色：选中、强调、徽标统一用它
    static let brand = Color(red: 0.45, green: 0.34, blue: 0.94)
    /// 选中底色浓度，深浅色一致，避免深色下发灰
    static let selectionFill = 0.14
    static let selectionStroke = 0.24
    /// 卡片 / 分组底色
    static let surface = 0.035
}

/// 字号阶梯：全应用只允许用这几档。
/// 档位比「看起来差不多大」更重要——同一层级的信息必须共用同一档。
enum TypeScale {
    /// 空状态主标题
    static let display = Font.system(size: 17, weight: .semibold)
    /// 卡片 / 详情标题
    static let title = Font.system(size: 12.5, weight: .semibold)
    /// 文件名、主要正文
    static let body = Font.system(size: 12.5)
    /// 面包屑、侧栏、工具栏按钮
    static let bodySmall = Font.system(size: 12)
    /// 数据列、说明文字、状态栏主文案
    static let label = Font.system(size: 11)
    /// 分区标题、次级信息
    static let caption = Font.system(size: 10.5)
    /// 胶囊标签、角标、浮动控件
    static let micro = Font.system(size: 9.5)
    /// 路径与代码
    static let mono = Font.system(size: 10.5, design: .monospaced)

    /// 数字列统一等宽数字，避免 109.1 KB 与 12.6 KB 的小数点错位
    static func data(_ size: CGFloat = 11) -> Font {
        .system(size: size).monospacedDigit()
    }
}

/// 间距阶梯：2 / 4 / 6 / 8 / 10 / 12 / 14 / 20，不接受 7、13 这类即兴值
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 14
    static let xxxl: CGFloat = 20
}

/// 尺寸与圆角统一在这里，别在各视图里各写一套魔法数字
enum Metrics {
    static let toolbarHeight: CGFloat = 44
    static let breadcrumbHeight: CGFloat = 32
    static let statusHeight: CGFloat = 26
    static let rowHeight: CGFloat = 28
    static let rowHeightWide: CGFloat = 38
    static let gutter: CGFloat = Space.xxl
    static let radiusPill: CGFloat = 4
    static let radiusRow: CGFloat = 6
    static let radiusThumb: CGFloat = 8
    static let radiusCard: CGFloat = 10
    static let radiusHero: CGFloat = 18
    /// 列表里「大小 / 修改时间」两列宽度，表头与行必须共用
    static let sizeColumn: CGFloat = 84
    static let dateColumn: CGFloat = 118
    /// 三栏各自的最小宽度：既是布局下限，也是自动切换阈值的推导输入。
    /// 外观改版调这三个数，Layout 的阈值会跟着走，不用回来改 autoMode。
    static let sidebarMin: CGFloat = 172
    static let contentMin: CGFloat = 360
    static let inspectorMin: CGFloat = 250
}

/// 窗口与模式切换的几何口径。
/// 阈值一律从 `Metrics` 推导，不写死数字——写死过一次 760/900，
/// 结果和窗口最小尺寸 1020 撞车，自动收起整整一版都没触发过。
enum Layout {
    /// 三栏几何上刚好放得下
    static var fullModeMinWidth: CGFloat {
        Metrics.sidebarMin + Metrics.contentMin + Metrics.inspectorMin + Metrics.gutter * 2 + 8
    }

    /// 舒适余量：刚到几何下限时内容列已经很挤，自动收起要提前一点
    static let comfortMargin: CGFloat = 180

    /// 低于它从完整模式收起（≈ 998）
    static var autoCollapseWidth: CGFloat { fullModeMinWidth + comfortMargin }

    /// 收缩与展开之间留滞回，避免拖动时来回弹
    static let hysteresis: CGFloat = 80

    /// 高于它从简化模式展开（≈ 1078）
    static var autoExpandWidth: CGFloat { autoCollapseWidth + hysteresis }

    /// 窗口最小尺寸与模式无关：只有解耦，窄窗口才可能真正出现
    static let minWindowWidth: CGFloat = 560
    static let minWindowHeight: CGFloat = 420

    /// 简化模式浮层预览的断点：窗口更窄时不浮层，改用空格快速查看
    static let overlayPreviewMinWidth: CGFloat = 620
}

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

/// 彩色图标徽标：圆角底 + 类型符号 + 一圈极细描边（浅色下不至于糊在背景里）
struct KindBadge: View {
    let kind: FileKind
    var side: CGFloat = 20
    var corner: CGFloat? = nil
    @Environment(\.colorScheme) private var scheme

    private var radius: CGFloat { corner ?? max(4, side * 0.26) }
    private var fillOpacity: Double { scheme == .dark ? 0.22 : 0.13 }
    private var strokeOpacity: Double { scheme == .dark ? 0.30 : 0.16 }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(kind.tint.opacity(fillOpacity))
            .frame(width: side, height: side)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(kind.tint.opacity(strokeOpacity), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: side * 0.52, weight: .medium))
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
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
            )
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// 工具栏图标按钮：hover 才有底色，图标用语义色，不抢主按钮的注意力
struct ToolButton: View {
    let symbol: String
    var help: String = ""
    var inactive: Bool = false
    var active: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? Palette.brand : Color.primary.opacity(0.82))
                .frame(width: 27, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering && !inactive ? Color.primary.opacity(0.065) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(inactive)
        .opacity(inactive ? 0.32 : 1)
        .help(help)
    }
}

/// 极细分割线：比 Divider 更克制，不会把界面切成一块块
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

extension View {
    /// 分组卡片：浅底色 + 细描边，替代一层层 Divider
    func cardSurface(radius: CGFloat = Metrics.radiusCard) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(Palette.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}
