// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import SwiftUI

/// 统一的配色：品牌青绿 + 按文件类型区分的色板。
/// 品牌色只用在「主操作 / 选中 / 强调」，其余一律走系统语义色，
/// 否则整条工具栏都是青的，层次会糊在一起。
extension AppearanceMode {
    /// 弹窗、小窗这些独立窗口读不到主窗口的 preferredColorScheme，只能自己读一次
    static var stored: AppearanceMode {
        UserDefaults.standard.string(forKey: "rrzip.appearance")
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}

extension Color {
    /// 按设计稿写色值：#00CFC3 比 Color(red: 0, green: 0.81, blue: 0.76) 好核对
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Color {
    /// 深/浅两套动态色：一处定义同时覆盖两种外观，调用方不用再读 colorScheme。
    /// alpha 也要能分开给——同一浓度压在深底和浅底上的观感差很多。
    static func adaptive(dark: UInt32, light: UInt32,
                         darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

enum Palette {
    /// 品牌色：选中、强调、徽标统一用它。
    /// 深色下提亮一档——#00CFC3 压在深底上会发闷；浅色下压深一档，白底上更清楚。
    static let brand = Color.adaptive(dark: 0x2FD3C5, light: 0x00C4B8)

    /// 窗口底 / 工具栏 / 输入框 / 卡片。
    /// 深色不用设计稿那套偏绿的灰（#263135 那几个）：四个色都在同一色相、
    /// 明度只差 10 出头，叠在一起整屏发绿灰、卡片浮不出来。
    /// 改成中性冷灰 + 逐级拉开明度，青绿只留给品牌色。
    static let window = Color.adaptive(dark: 0x1C1F21, light: 0xFDFDFD)
    static let chrome = Color.adaptive(dark: 0x232729, light: 0xF5F6F7)
    static let card   = Color.adaptive(dark: 0x282D30, light: 0xFFFFFF)
    static let field  = Color.adaptive(dark: 0x333A3D, light: 0xEDEFF1)
    /// 选中底色与描边。固定 0.14 在深底上几乎看不见，改成按外观给不同浓度
    static let selectionFill = Color.adaptive(dark: 0x2FD3C5, light: 0x00C4B8,
                                              darkAlpha: 0.20, lightAlpha: 0.14)
    static let selectionStroke = Color.adaptive(dark: 0x2FD3C5, light: 0x00C4B8,
                                                darkAlpha: 0.36, lightAlpha: 0.26)
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
    static let rowHeight: CGFloat = 32
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

    /// 舒适余量：三栏几何下限保证「放得下」，这里再加一段「不那么挤」的缓冲。
    ///
    /// 实测教训（2026-11-06）：留 180 时展开阈值被推到 1078，用户把窗口拉到 1044
    /// 还没反应，体感就是「自动切换坏了」；留 100 仍然嫌高。
    /// 结论：宁可在下限处就切、让三栏紧一点，也不要让阈值跑到用户够不到的地方。
    /// 现在等于不留余量，展开 898 / 收起 818 —— 都在「800 多」区间内。
    static let comfortMargin: CGFloat = 0

    /// 低于它从完整模式收起（= 818，等于三栏几何下限）
    static var autoCollapseWidth: CGFloat { fullModeMinWidth + comfortMargin }

    /// 收缩与展开之间留滞回，避免拖动时来回弹
    static let hysteresis: CGFloat = 80

    /// 高于它从简化模式展开（= 898，留 80 的滞回）
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

    /// 类型主色。全部改成与青绿品牌能放在一起的低饱和色板。
    ///
    /// 两条硬规则：
    /// 1. **不许出现紫色**。压缩包以前是 `#8C5CF5`，欢迎页那颗大徽标、列表每行、
    ///    详情栏头部全是它，品牌换青绿之后整屏最显眼的仍是那块紫——这就是「紫色 logo
    ///    还在」的来源。压缩包是本应用的主角，直接用品牌色。
    /// 2. 磁盘以前是靛蓝 `#5C6ECC`，和紫只差一点色相，一并挪到明确的蓝。
    var tint: Color {
        switch self {
        case .folder: return Color(hex: 0x3B82F6)
        case .archive: return Palette.brand
        case .image: return Color(hex: 0xF59E0B)
        case .pdf: return Color(hex: 0xE5484D)
        case .video: return Color(hex: 0xEC6A9C)
        case .audio: return Color(hex: 0x0EA5B7)
        case .code: return Color(hex: 0x2FA55F)
        case .text: return Color(hex: 0x66788F)
        case .disk: return Color(hex: 0x4763B8)
        case .other: return Color(hex: 0x8B9099)
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
