// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import AppKit
import ImageIO
import PDFKit
import SwiftUI

/// 条目缩略图：按需解压 → 降采样（图片走 ImageIO，PDF 渲染首页）→ 内存缓存。
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, CGImageBox>()
    private var inFlight = Set<String>()

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"
    ]
    /// 超过 12 MB 的图片不做缩略图，避免为了看一眼解压 20 MB
    private static let imageSizeLimit: Int64 = 12 * 1024 * 1024
    /// PDF 首页渲染稍贵，阈值放宽到 40 MB
    private static let pdfSizeLimit: Int64 = 40 * 1024 * 1024

    /// NSCache 只收对象，包一层
    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func supports(_ entry: ArchiveEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        if Self.imageExts.contains(entry.ext) { return entry.size <= Self.imageSizeLimit }
        if entry.ext == "pdf" { return entry.size <= Self.pdfSizeLimit }
        return false
    }

    /// `maxPixel` 越大越清晰，同时用于缓存分档（列表 20pt / 网格 56pt / 悬停 640px）
    func thumbnail(
        for entry: ArchiveEntry,
        model: ArchiveModel,
        maxPixel: CGFloat = 160,
        completion: @escaping (CGImage?) -> Void
    ) {
        let archivePath = model.current?.archive.path ?? ""
        let bucket = Int(maxPixel.rounded())
        let key = "\(archivePath)|\(entry.id)|\(bucket)" as NSString
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
                    if let image { self.cache.setObject(CGImageBox(image), forKey: key) }
                    completion(image)
                }
            }
        }
    }

    // MARK: - 渲染

    nonisolated private static func render(url: URL, ext: String, maxPixel: CGFloat) -> CGImage? {
        if ext == "pdf" { return pdfFirstPage(url: url, maxPixel: maxPixel) }
        return downsample(url: url, maxPixel: maxPixel)
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
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        context.cgContext.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }
}

/// 行/网格里的缩略图视图：先显示占位图标，加载完成再换成图。
struct EntryThumbnail: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    var side: CGFloat = 20
    var corner: CGFloat = 3

    @State private var image: CGImage?
    @State private var requested = false

    var body: some View {
        Group {
            if let image {
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
        .onAppear(perform: request)
    }

    private func request() {
        guard !requested, ThumbnailStore.shared.supports(entry) else { return }
        requested = true
        // 大图标要更清晰，按显示尺寸给 2 倍像素
        let pixel = max(160, side * 2)
        ThumbnailStore.shared.thumbnail(for: entry, model: model, maxPixel: pixel) { loaded in
            if let loaded { image = loaded }
        }
    }

    private var fallbackSymbol: String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isArchive { return "shippingbox.fill" }
        switch entry.ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "flac", "wav", "m4a": return "music.note"
        default: return "doc"
        }
    }
}
