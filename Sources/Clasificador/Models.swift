import Foundation
import SwiftUI

// MARK: - Dónde vive todo

enum Rutas {
    /// Carpeta general del proyecto: dentro viven el código (`App/`) y las fotos.
    static var raizProyecto: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Clasificador de Fotos")
    }

    /// Todas las fotos, con una carpeta por sesión dentro.
    static var raizFotos: URL { raizProyecto.appendingPathComponent("Fotos") }

    /// Carpeta de cada sesión. El nombre se limpia de caracteres que no valen.
    static func carpetaSesion(_ nombre: String) -> URL {
        var limpio = nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        for malo in [":", "/"] { limpio = limpio.replacingOccurrences(of: malo, with: "-") }
        return raizFotos.appendingPathComponent(limpio.isEmpty ? "Sesión" : limpio)
    }

    /// Subcarpeta con lo que aún no has clasificado.
    static let pendientes = "Pendientes"
}

// MARK: - Categorías

/// Una categoría de clasificación. `folders` son las subcarpetas destino donde
/// se copia el archivo: varias entradas significan que se copia en todas (Todos),
/// y vacío significaría no copiar a ningún sitio (hoy ninguna lo usa).
struct Category: Identifiable, Codable, Hashable {
    /// Identidad ESTABLE. Es lo que se guarda en `MediaItem.decision`, así que no
    /// se puede renumerar: cambiarlo convertiría decisiones ya tomadas en otras.
    /// La tecla NO es esto: sale de la posición dentro de la sesión.
    var id: Int
    var name: String
    var folders: [String]
    var tintHex: String
    var symbol: String

    var tint: Color { Color(hex: tintHex) }

    /// Categorías de arranque, pensadas para repartir fotos entre dos personas.
    /// Se pueden renombrar en la app y cada sesión guarda las suyas.
    /// "Las dos" copia en las dos carpetas personales y además en la suya;
    /// "Descartar" copia en "Descartadas", para poder repescarlas sin ir a
    /// buscar el original.
    static let defaults: [Category] = [
        Category(id: 1, name: "Persona 1", folders: ["Persona 1"],
                 tintHex: "#4F8DF7", symbol: "person.fill"),
        Category(id: 2, name: "Persona 2", folders: ["Persona 2"],
                 tintHex: "#E5645C", symbol: "heart.fill"),
        Category(id: 3, name: "Las dos", folders: ["Persona 1", "Persona 2", "Las dos"],
                 tintHex: "#3FB27F", symbol: "person.2.fill"),
        Category(id: 4, name: "Descartar", folders: ["Descartadas"],
                 tintHex: "#8A8A8E", symbol: "trash.fill"),
    ]

    /// Carpeta donde van las descartadas. Se usa también para poner al día
    /// sesiones guardadas antes de que «Descartar» copiase a algún sitio.
    static let carpetaDescartadas = "Descartadas"

    /// Catálogo de todas las clasificaciones disponibles al crear una sesión.
    /// Cada sesión se queda con las que elijas, en este mismo orden.
    static var catalogo: [Category] { defaults }
}

// MARK: - Elementos del pool

enum MediaKind: String, Codable { case image, video }

struct MediaItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var url: URL
    var kind: MediaKind
    var fileSize: Int64 = 0
    var date: Date?                 // fecha EXIF / del contenedor, o del fichero
    var dateSource: String = ""     // "EXIF", "vídeo", "archivo"
    var width: Int = 0
    var height: Int = 0
    var duration: Double = 0        // solo vídeos, en segundos

    var contentHash: String?        // SHA-256, solo si hizo falta comprobar
    var duplicateOfName: String?    // nombre del archivo idéntico ya visto

    var decision: Int?              // id de categoría, nil = sin clasificar

    // Todo lo de abajo es opcional a propósito: así una sesión guardada por una
    // versión anterior (sin estos campos) se sigue leyendo sin romperse.
    var rotation: Int?              // 0/90/180/270, se aplica a la copia
    var camera: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var shutter: String?
    var focalLength: Double?
    var latitude: Double?
    var longitude: Double?

    var name: String { url.lastPathComponent }
    var isDuplicate: Bool { duplicateOfName != nil }
    var rot: Int { ((rotation ?? 0) % 360 + 360) % 360 }
    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Datos de cámara para el panel, ya formateados y sin huecos.
    var cameraLines: [(String, String)] {
        var out: [(String, String)] = []
        if let c = camera { out.append(("Cámara", c)) }
        if let l = lens { out.append(("Objetivo", l)) }
        if let f = focalLength { out.append(("Focal", String(format: "%.0f mm", f))) }
        if let a = aperture { out.append(("Apertura", String(format: "ƒ/%.1f", a))) }
        if let s = shutter { out.append(("Exposición", s)) }
        if let i = iso { out.append(("ISO", "\(i)")) }
        return out
    }

    static func == (a: MediaItem, b: MediaItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Una decisión ya aplicada, con los archivos que se crearon, para poder deshacer.
struct Decision: Codable {
    var itemID: UUID
    var itemIndex: Int
    var categoryID: Int
    var createdFiles: [URL]
    /// Si al clasificar se quitó su copia de «Pendientes», aquí queda apuntada
    /// para poder devolverla al deshacer. Opcional: las decisiones guardadas
    /// antes de que existiera «Pendientes» no la traen.
    var pendienteBorrada: URL?
}

// MARK: - Estado persistido

/// El contenido completo de UNA sesión. Cada sesión tiene su propio pool, sus
/// decisiones, su historial y su carpeta destino, independientes de las demás.
struct SessionState: Codable {
    var id: UUID = UUID()
    var name: String = "Sesión"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var items: [MediaItem] = []
    var currentIndex: Int = 0
    var destinationRoot: URL
    var categories: [Category] = Category.defaults
    var history: [Decision] = []

    /// Decodificador tolerante: los campos nuevos pueden faltar, para poder leer
    /// una sesión guardada por una versión anterior de la app sin perderla.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Sesión"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        items = try c.decodeIfPresent([MediaItem].self, forKey: .items) ?? []
        currentIndex = try c.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
        destinationRoot = try c.decode(URL.self, forKey: .destinationRoot)
        categories = try c.decodeIfPresent([Category].self, forKey: .categories) ?? Category.defaults
        history = try c.decodeIfPresent([Decision].self, forKey: .history) ?? []
    }

    init(name: String, destinationRoot: URL, categories: [Category] = Category.defaults) {
        self.name = name
        self.destinationRoot = destinationRoot
        self.categories = categories
    }
}

/// Ficha ligera de una sesión, para poder pintar la lista sin abrir cada archivo.
struct SessionMeta: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var itemCount: Int
    var pendingCount: Int

    var doneCount: Int { max(0, itemCount - pendingCount) }
}

/// Índice de todas las sesiones y cuál está abierta.
struct SessionIndex: Codable {
    var activeID: UUID?
    var sessions: [SessionMeta] = []
}

// MARK: - Utilidades

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension String {
    var nilSiVacio: String? { isEmpty ? nil : self }
}

extension Int64 {
    var humanSize: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: self)
    }
}

extension Date {
    var spanish: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM yyyy · HH:mm"
        return f.string(from: self)
    }
}
