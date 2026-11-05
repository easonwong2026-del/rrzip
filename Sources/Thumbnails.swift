import AppKit
import ImageIO
import SwiftUI

/// 图片条目的缩略图。按需解压 → 降采样 → 内存缓存，超过阈值的文件不生成。
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight = Set<String>()
    private let limit = DispatchSemaphore(value: 4)   // 同时最多 4 个解压任务

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"
    ]
    /// 超过 12 MB 的图片不做缩略图，避免为了看一眼解压 20 MB
    private static let sizeLimit: Int64 = 12 * 1024 * 1024

    func supports(_ entry: ArchiveEntry) -> Bool {
        !entry.isDirectory && Self.imageExts.contains(entry.ext) && entry.size <= Self.sizeLimit
    }

    func thumbnail(for entry: ArchiveEntry, model: ArchiveModel, completion: @escaping (NSImage?) -> Void) {
        let key = entry.id as NSString
        if let cached = cache.object(forKey: key) {
            return completion(cached)
        }
        guard supports(entry), !inFlight.contains(entry.id) else {
            return completion(nil)
        }
        inFlight.insert(entry.id)

        model.payloadURL(for: entry) { url in
            guard let url else {
                Task { @MainActor in self.inFlight.remove(entry.id) }
                return completion(nil)
            }
            Task.detached(priority: .utility) {
                let image = Self.downsample(url: url, maxPixel: 160)
                await MainActor.run {
                    self.inFlight.remove(entry.id)
                    if let image { self.cache.setObject(image, forKey: key) }
                    completion(image)
                }
            }
        }
    }

    nonisolated private static func downsample(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// 行/网格里的缩略图视图：先显示占位图标，加载完成再换成图。
struct EntryThumbnail: View {
    let entry: ArchiveEntry
    @ObservedObject var model: ArchiveModel
    var side: CGFloat = 20
    var corner: CGFloat = 3

    @State private var image: NSImage?
    @State private var requested = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
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
        ThumbnailStore.shared.thumbnail(for: entry, model: model) { loaded in
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
