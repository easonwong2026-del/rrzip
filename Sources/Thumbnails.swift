// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import AVFoundation
import ImageIO
import PDFKit
import SwiftUI

/// 条目缩略图：按需解压 → 降采样（图片走 ImageIO，PDF 渲染首页）→ 内存缓存。
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, CGImageBox>()
    private var inFlight = Set<String>()
    /// 缩略图落盘后自增：视图只读缓存，靠这个信号刷新，避免依赖 @State
    @Published private(set) var version = 0

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"
    ]
    /// 超过 12 MB 的图片不做缩略图，避免为了看一眼解压 20 MB
    private static let imageSizeLimit: Int64 = 12 * 1024 * 1024
    /// PDF 首页渲染稍贵，阈值放宽到 40 MB
    private static let pdfSizeLimit: Int64 = 40 * 1024 * 1024
    /// 视频只取一张首帧，但解压本身要落盘，限制到 300 MB
    private static let videoSizeLimit: Int64 = 300 * 1024 * 1024
    /// AVFoundation 能解的容器（mkv/avi 不在此列，避免白跑一趟）
    nonisolated private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mpg", "mpeg"]

    /// NSCache 只收对象，包一层
    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func supports(_ entry: ArchiveEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        if Self.imageExts.contains(entry.ext) { return entry.size <= Self.imageSizeLimit }
        if entry.ext == "pdf" { return entry.size <= Self.pdfSizeLimit }
        if Self.videoExts.contains(entry.ext) { return entry.size <= Self.videoSizeLimit }
        return false
    }

    private func cacheKey(for entry: ArchiveEntry, model: ArchiveModel, maxPixel: CGFloat) -> NSString {
        let archivePath = model.current?.archive.path ?? ""
        return "\(archivePath)|\(entry.id)|\(Int(maxPixel.rounded()))" as NSString
    }

    /// 只查缓存，不触发加载
    func cached(for entry: ArchiveEntry, model: ArchiveModel, maxPixel: CGFloat) -> CGImage? {
        cache.object(forKey: cacheKey(for: entry, model: model, maxPixel: maxPixel))?.image
    }

    /// 触发加载；结果进缓存并自增 version
    func request(for entry: ArchiveEntry, model: ArchiveModel, maxPixel: CGFloat) {
        guard supports(entry) else { return }
        let key = cacheKey(for: entry, model: model, maxPixel: maxPixel)
        guard cache.object(forKey: key) == nil, !inFlight.contains(key as String) else { return }
        inFlight.insert(key as String)

        let ext = entry.ext
        model.payloadURL(for: entry) { url in
            guard let url else {
                Task { @MainActor in self.inFlight.remove(key as String) }
                return
            }
            Task.detached(priority: .utility) {
                let image = Self.render(url: url, ext: ext, maxPixel: maxPixel)
                await MainActor.run {
                    self.inFlight.remove(key as String)
                    guard let image else { return }
                    self.cache.setObject(CGImageBox(image), forKey: key)
                    self.version &+= 1
                }
            }
        }
    }

    /// `maxPixel` 越大越清晰，同时用于缓存分档（列表 20pt / 网格 56pt / 悬停 640px）
    func thumbnail(
        for entry: ArchiveEntry,
        model: ArchiveModel,
        maxPixel: CGFloat = 160,
        completion: @escaping (CGImage?) -> Void
    ) {
        let key = cacheKey(for: entry, model: model, maxPixel: maxPixel)
        if let cached = cache.object(forKey: key) {
            return completion(cached.image)
        }
        guard supports(entry), !inFlight.contains(key as String) else {
            return completion(nil)
        }
        inFlight.insert(key as String)

        let ext = entry.ext
        model.payloadURL(for: entry) { url in
            guard let url else {
                Task { @MainActor in self.inFlight.remove(key as String) }
                return completion(nil)
            }
            Task.detached(priority: .utility) {
                let image = Self.render(url: url, ext: ext, maxPixel: maxPixel)
                await MainActor.run {
                    self.inFlight.remove(key as String)
                    if let image {
                        self.cache.setObject(CGImageBox(image), forKey: key)
                        self.version &+= 1
                    }
                    completion(image)
                }
            }
        }
    }

    /// 供命令行与测试调用：解压指定条目并渲染缩略图，不经过缓存
    nonisolated static func renderForTool(url: URL, ext: String, maxPixel: CGFloat) -> CGImage? {
        render(url: url, ext: ext, maxPixel: maxPixel)
    }

    // MARK: - 渲染

    nonisolated private static func render(url: URL, ext: String, maxPixel: CGFloat) -> CGImage? {
        if ext == "pdf" { return pdfFirstPage(url: url, maxPixel: maxPixel) }
        if videoExts.contains(ext) { return videoFirstFrame(url: url, maxPixel: maxPixel) }
        return downsample(url: url, maxPixel: maxPixel)
    }

    /// 取视频首帧：优先 1 秒处（纯黑开场也能拿到画面），短片则取开头
    nonisolated private static func videoFirstFrame(url: URL, maxPixel: CGFloat) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        // 先试 1 秒（避开纯黑开场），失败或短片时退回第一帧
        func frame(at seconds: Double) -> CGImage? {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            return try? generator.copyCGImage(at: time, actualTime: nil)
        }
        return frame(at: 1.0) ?? frame(at: 0.0)
    }

    nonisolated private static func downsample(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 渲染 PDF 首页。先画进位图再返回：NSImage 的延迟绘制在后台线程下拿不到结果，
    /// 而且位图能保证白底不透明，缩略图不会透出窗口背景。
    nonisolated private static func pdfFirstPage(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let document = PDFDocument(url: url),
              document.pageCount > 0,
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let scale = maxPixel / max(bounds.width, bounds.height)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // 用 CGContext 直接铺白底：NSColor / NSRect.fill 在离屏位图上不可靠
        let cg = context.cgContext
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: cg)
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }
}

/// 行/网格里的缩略图视图：只读 store 的缓存，加载完成后由 version 触发重绘。
/// 不把图片放进 @State —— 列表滚动会重建视图，@State 会丢。
struct EntryThumbnail: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    @ObservedObject private var store = ThumbnailStore.shared
    var side: CGFloat = 20
    var corner: CGFloat = 3

    /// 大图标要更清晰，按显示尺寸给 2 倍像素
    private var pixel: CGFloat { max(160, side * 2) }

    var body: some View {
        Group {
            if let image = store.cached(for: entry, model: model, maxPixel: pixel) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner)
                            .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: side * 0.62))
                    .foregroundStyle(entry.isArchive ? Color.accentColor : Color.secondary)
                    .frame(width: side, height: side)
            }
        }
        .onAppear {
            store.request(for: entry, model: model, maxPixel: pixel)
        }
    }

    private var fallbackSymbol: String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isArchive { return "shippingbox.fill" }
        switch entry.ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "m4v", "mpg", "mpeg": return "film"
        case "mp3", "flac", "wav", "m4a": return "music.note"
        default: return "doc"
        }
    }
}
