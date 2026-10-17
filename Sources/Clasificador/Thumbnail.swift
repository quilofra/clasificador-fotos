import AVFoundation
import AppKit
import ImageIO
import SwiftUI

/// Miniaturas bajo demanda con caché. Usa CGImageSource, que reduce la imagen
/// sin decodificarla entera: imprescindible para un pool de decenas de miles.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    // La clave lleva el tamaño: una miniatura hecha para la tira (46 px) se
    // vería borrosa reaprovechada en el Historial (104 px).
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 800

    func image(for url: URL, kind: MediaKind, size: CGFloat) -> NSImage? {
        let clave = "\(Int(size))|\(url.path)"
        if let c = cache[clave] { return c }
        let img: NSImage?
        switch kind {
        case .image: img = Self.imageThumb(url, size)
        case .video: img = Self.videoThumb(url, size)
        }
        if let img {
            cache[clave] = img
            order.append(clave)
            if order.count > limit {
                let drop = order.removeFirst()
                cache.removeValue(forKey: drop)
            }
        }
        return img
    }

    private static func imageThumb(_ url: URL, _ size: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size * 2,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func videoThumb(_ url: URL, _ size: CGFloat) -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size * 2, height: size * 2)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 60),
                                            actualTime: nil)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct Thumb: View {
    let item: MediaItem
    var size: CGFloat = 44

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: item.kind == .video ? "film" : "photo")
                    .foregroundStyle(.tertiary)
            }
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 2)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.url) {
            image = await ThumbnailCache.shared.image(for: item.url, kind: item.kind, size: size)
        }
    }
}
