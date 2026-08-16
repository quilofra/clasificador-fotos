import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// Rastrea carpetas y archivos, lee metadatos y detecta duplicados por contenido.
enum MediaScanner {

    static let imageExt: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
    ]
    static let videoExt: Set<String> = ["mp4", "mov", "m4v"]

    static func kind(for url: URL) -> MediaKind? {
        let e = url.pathExtension.lowercased()
        if imageExt.contains(e) { return .image }
        if videoExt.contains(e) { return .video }
        return nil
    }

    /// Expande carpetas recursivamente y devuelve los archivos soportados.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let en = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let f = en?.nextObject() as? URL {
                    if kind(for: f) != nil { out.append(f) }
                }
            } else if kind(for: url) != nil {
                out.append(url)
            }
        }
        return out
    }

    /// Construye los elementos leyendo tamaño y fecha de cada archivo.
    static func makeItems(from urls: [URL],
                          progress: @escaping @Sendable (Int, Int) -> Void) async -> [MediaItem] {
        var items: [MediaItem] = []
        items.reserveCapacity(urls.count)
        let total = urls.count

        for (i, url) in urls.enumerated() {
            guard let k = kind(for: url) else { continue }
            var item = MediaItem(url: url, kind: k)

            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            item.fileSize = Int64(vals?.fileSize ?? 0)

            switch k {
            case .image:
                readImageMetadata(&item)
            case .video:
                await readVideoMetadata(&item)
            }

            if item.date == nil {
                item.date = vals?.contentModificationDate
                item.dateSource = "archivo"
            }
            items.append(item)

            if i % 50 == 0 { progress(i, total) }
        }
        progress(total, total)
        return items
    }

    private static func readImageMetadata(_ item: inout MediaItem) {
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return }

        item.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        item.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let s = (exif[kCGImagePropertyExifDateTimeOriginal]
                        ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String,
               let d = exifFormatter.date(from: s) {
                item.date = d
                item.dateSource = "EXIF"
            }
            item.lens = exif[kCGImagePropertyExifLensModel] as? String
            item.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            item.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            item.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                item.shutter = t >= 1 ? String(format: "%.1f s", t)
                                      : "1/\(Int((1 / t).rounded())) s"
            }
        }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let marca = tiff[kCGImagePropertyTIFFMake] as? String
            let modelo = tiff[kCGImagePropertyTIFFModel] as? String
            item.camera = [marca, modelo].compactMap { $0 }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
                .nilSiVacio
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let ew = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            item.latitude = ns == "S" ? -lat : lat
            item.longitude = ew == "W" ? -lon : lon
        }
    }

    private static func readVideoMetadata(_ item: inout MediaItem) async {
        let asset = AVURLAsset(url: item.url)
        if let d = try? await asset.load(.duration) {
            item.duration = CMTimeGetSeconds(d)
            if item.duration.isNaN || item.duration.isInfinite { item.duration = 0 }
        }
        if let created = try? await asset.load(.creationDate),
           let d = try? await created.load(.dateValue) {
            item.date = d
            item.dateSource = "vídeo"
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            item.width = Int(abs(size.width))
            item.height = Int(abs(size.height))
        }

        // Ubicación en formato ISO 6709, p. ej. "+40.4168-003.7038/"
        if let meta = try? await asset.load(.commonMetadata) {
            for m in meta where m.commonKey == .commonKeyLocation {
                guard let texto = try? await m.load(.stringValue),
                      let (la, lo) = Self.iso6709(texto) else { continue }
                item.latitude = la
                item.longitude = lo
            }
        }
    }

    /// Extrae latitud y longitud de una cadena ISO 6709 partiéndola por los signos.
    static func iso6709(_ s: String) -> (Double, Double)? {
        var nums: [Double] = []
        var actual = ""
        func cerrar() {
            if actual.count > 1, let v = Double(actual) { nums.append(v) }
            actual = ""
        }
        for ch in s {
            if ch == "+" || ch == "-" {
                cerrar()
                actual = String(ch)
            } else if ch.isNumber || ch == "." {
                if !actual.isEmpty { actual.append(ch) }
            } else {
                cerrar()
            }
        }
        cerrar()
        return nums.count >= 2 ? (nums[0], nums[1]) : nil
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Duplicados

    /// Marca duplicados exactos por contenido. Para no leer 20 GB, primero agrupa
    /// por tamaño y solo calcula el hash de los que comparten tamaño con otro:
    /// dos archivos distintos casi nunca pesan exactamente lo mismo.
    static func markDuplicates(_ items: inout [MediaItem],
                               progress: @escaping @Sendable (Int, Int) -> Void) {
        var bySize: [Int64: [Int]] = [:]
        for (i, it) in items.enumerated() where it.fileSize > 0 {
            bySize[it.fileSize, default: []].append(i)
        }
        let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        let total = candidates.count
        guard total > 0 else { progress(0, 0); return }

        var seen: [String: String] = [:]   // hash -> primer nombre con ese hash
        for (n, idx) in candidates.enumerated() {
            guard let h = sha256(items[idx].url) else { continue }
            items[idx].contentHash = h
            if let first = seen[h] {
                items[idx].duplicateOfName = first
            } else {
                seen[h] = items[idx].name
            }
            if n % 25 == 0 { progress(n, total) }
        }
        progress(total, total)
    }

    private static func sha256(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
