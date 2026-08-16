import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rotación SIN PÉRDIDA aplicada a la copia ya escrita en el destino.
///
/// - Fotos: se reescribe solo la etiqueta EXIF de orientación. `CGImageDestination
///   AddImageFromSource` copia los datos comprimidos tal cual y únicamente cambia
///   los metadatos, así que el JPEG no se vuelve a codificar.
/// - Vídeos: se parchea la matriz de transformación del átomo `tkhd`, in situ.
///   El fichero no cambia de tamaño.
enum Rotator {

    /// Aplica `grados` (90/180/270) al archivo. Devuelve false si no pudo.
    @discardableResult
    static func apply(_ grados: Int, to url: URL, kind: MediaKind) -> Bool {
        let g = ((grados % 360) + 360) % 360
        guard g != 0 else { return true }
        switch kind {
        case .image: return rotarImagen(g, url)
        case .video: return rotarVideo(g, url)
        }
    }

    // MARK: - Fotos: solo la etiqueta de orientación

    /// Orientaciones EXIF encadenadas. El valor 1 es «sin rotar»; 6/3/8 son
    /// 90°/180°/270° en sentido horario.
    private static let porGrados: [Int: Int] = [90: 6, 180: 3, 270: 8]

    /// Tabla de composición: al girar una imagen que ya venía orientada, hay que
    /// combinar ambas rotaciones en lugar de pisar la que traía.
    private static func componer(_ actual: Int, _ grados: Int) -> Int {
        // pasos de 90° que representa cada orientación EXIF (solo las no espejadas)
        let pasos: [Int: Int] = [1: 0, 6: 1, 3: 2, 8: 3]
        let inverso: [Int: Int] = [0: 1, 1: 6, 2: 3, 3: 8]
        guard let p = pasos[actual] else { return porGrados[grados] ?? 1 }
        return inverso[(p + grados / 90) % 4] ?? 1
    }

    private static func rotarImagen(_ grados: Int, _ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let tipo = CGImageSourceGetType(src),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return false }

        let actual = props[kCGImagePropertyOrientation] as? Int ?? 1
        let nueva = componer(actual, grados)
        props[kCGImagePropertyOrientation] = nueva
        // TIFF lleva su propia copia de la orientación; si no se actualiza, hay
        // visores que leen la vieja y la foto sale girada al revés.
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nueva
            props[kCGImagePropertyTIFFDictionary] = tiff
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".rot-\(UUID().uuidString)")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, tipo, 1, nil)
        else { return false }

        // CopyImageSource reescribe SOLO los metadatos y deja los datos
        // comprimidos intactos. AddImageFromSource, en cambio, vuelve a
        // codificar la imagen (comprobado: un JPEG de 135 KB salía de 182 KB).
        var opciones: [CFString: Any] = [:]
        opciones[kCGImageDestinationOrientation] = nueva
        opciones[kCGImageDestinationMergeMetadata] = true

        var err: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(dst, src, opciones as CFDictionary, &err)
        guard ok else {
            err?.release()
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        _ = props   // las propiedades ya viajan dentro de la copia

        // conservar las fechas del archivo original al sustituirlo
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        if let attrs, let mod = attrs[.modificationDate] as? Date {
            try? FileManager.default.setAttributes(
                [.modificationDate: mod, .creationDate: attrs[.creationDate] ?? mod],
                ofItemAtPath: url.path)
        }
        return true
    }

    // MARK: - Vídeos: matriz del tkhd

    /// Estructura del tkhd tras el `size`+`type`:
    ///   version(1)+flags(3) · tiempos+id+reservado+duración (20 en v0, 32 en v1)
    ///   · reservado(8)+layer(2)+altGroup(2)+volume(2)+reservado(2) = 16
    ///   · matriz 3x3 (36) · width(4) · height(4)
    private static func offsetMatriz(version: UInt8, cuerpo: Int) -> Int {
        cuerpo + 4 + (version == 1 ? 32 : 20) + 16
    }

    private static func rotarVideo(_ grados: Int, _ url: URL) -> Bool {
        var tocados = 0
        guard let fh = try? FileHandle(forUpdating: url) else { return false }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        let total = Int(fh.offsetInFile)

        func leerI32(_ off: Int) -> Int32 {
            fh.seek(toFileOffset: UInt64(off))
            guard let d = try? fh.read(upToCount: 4), d.count == 4 else { return 0 }
            return d.withUnsafeBytes { $0.load(as: Int32.self).bigEndian }
        }

        func recorrer(_ inicio: Int, _ fin: Int, _ prof: Int) {
            var pos = inicio
            while pos + 8 <= fin && prof < 6 {
                fh.seek(toFileOffset: UInt64(pos))
                guard let cab = try? fh.read(upToCount: 8), cab.count == 8 else { return }
                var tam = Int(cab[0]) << 24 | Int(cab[1]) << 16 | Int(cab[2]) << 8 | Int(cab[3])
                let tipo = String(bytes: cab[4..<8], encoding: .ascii) ?? ""
                var cuerpo = pos + 8
                if tam == 1 {
                    guard let ext = try? fh.read(upToCount: 8), ext.count == 8 else { return }
                    tam = ext.reduce(0) { $0 << 8 | Int($1) }
                    cuerpo = pos + 16
                } else if tam == 0 {
                    tam = fin - pos
                }
                guard tam >= 8, pos + tam <= fin else { return }

                if tipo == "tkhd" {
                    fh.seek(toFileOffset: UInt64(cuerpo))
                    guard let v = try? fh.read(upToCount: 1), let ver = v.first else { return }
                    let m = offsetMatriz(version: ver, cuerpo: cuerpo)

                    // ángulo que ya tenía, deducido de a y b (ambos 16.16)
                    let a = Double(leerI32(m)) / 65536
                    let b = Double(leerI32(m + 4)) / 65536
                    let previo = Int((atan2(b, a) * 180 / .pi).rounded())
                    let acumulado = (((previo + grados) % 360) + 360) % 360

                    // dimensiones de la pista, para colocar bien el resultado
                    let w = Double(leerI32(m + 36)) / 65536
                    let h = Double(leerI32(m + 40)) / 65536
                    // las pistas de audio miden 0x0: ahí la matriz no pinta nada
                    guard w > 0, h > 0 else { pos += tam; continue }

                    let rad = Double(acumulado) * .pi / 180
                    let co = (cos(rad) * 65536).rounded()
                    let si = (sin(rad) * 65536).rounded()
                    let (tx, ty): (Double, Double)
                    switch acumulado {
                    case 90:  (tx, ty) = (h, 0)
                    case 180: (tx, ty) = (w, h)
                    case 270: (tx, ty) = (0, w)
                    default:  (tx, ty) = (0, 0)
                    }

                    // a b u | c d v | x y w   (u,v,w en 2.30; w = 1.0)
                    let valores: [Int32] = [
                        Int32(co), Int32(si), 0,
                        Int32(-si), Int32(co), 0,
                        Int32((tx * 65536).rounded()), Int32((ty * 65536).rounded()),
                        0x4000_0000,
                    ]
                    var datos = Data()
                    for x in valores {
                        var be = x.bigEndian
                        datos.append(Data(bytes: &be, count: 4))
                    }
                    fh.seek(toFileOffset: UInt64(m))
                    fh.write(datos)
                    tocados += 1
                } else if ["moov", "trak", "edts", "mdia", "minf", "udta"].contains(tipo) {
                    recorrer(cuerpo, pos + tam, prof + 1)
                }
                pos += tam
            }
        }
        recorrer(0, total, 0)
        return tocados > 0
    }
}
