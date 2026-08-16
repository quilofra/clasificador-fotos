import Foundation
import SwiftUI

/// Copia con "copy on write" de APFS: instantánea y sin ocupar disco hasta que
/// una de las dos versiones cambie. El resultado es un archivo normal y corriente,
/// no un alias: si borras el original, la copia sigue entera.
@_silgen_name("clonefile")
func clonefile(_ src: UnsafePointer<CChar>, _ dst: UnsafePointer<CChar>, _ flags: Int32) -> Int32

@MainActor
final class AppStore: ObservableObject {

    /// Cualquier cambio en el pool tira los contadores cacheados. Da igual quién
    /// lo toque (clasificar, deshacer, repescar…): así nunca se quedan viejos.
    @Published var items: [MediaItem] = [] {
        didSet { cacheConteos = nil; cacheDuplicados = nil }
    }
    @Published var currentIndex: Int = 0
    @Published var categories: [Category] = Category.defaults
    @Published var history: [Decision] = []

    // Sesiones: cada una es un pool independiente con sus propias decisiones.
    @Published var sessions: [SessionMeta] = []
    @Published var activeSessionID: UUID = UUID()
    @Published var sessionName: String = "Sesión"
    var sessionCreatedAt: Date = Date()

    /// Cada sesión guarda dentro de su propia carpeta, bajo la raíz común.
    @Published var destinationRoot: URL = Rutas.carpetaSesion("Sesión")

    /// Lo enciende el menú Archivo para que la ventana abra el diálogo de nombre.
    @Published var showNewSessionDialog = false

    @Published var isScanning = false
    @Published var scanMessage = ""
    @Published var scanProgress: Double = 0
    @Published var lastError: String?

    // MARK: - Derivados

    private var cacheConteos: [Int: Int]?
    private var cacheDuplicados: Int?
    private var tareaGuardado: Task<Void, Never>?

    /// Un solo recorrido del pool para todos los contadores. Con 32.000 fotos,
    /// contarlos por separado en cada refresco costaba unos 11 ms por pintada.
    /// La clave 0 son las que están sin clasificar.
    private var conteos: [Int: Int] {
        if let c = cacheConteos { return c }
        var c: [Int: Int] = [:]
        for it in items { c[it.decision ?? 0, default: 0] += 1 }
        cacheConteos = c
        return c
    }

    var current: MediaItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }
    var pendingCount: Int { conteos[0] ?? 0 }
    var hasPending: Bool { pendingCount > 0 }
    var doneCount: Int { items.count - pendingCount }
    func count(for categoryID: Int) -> Int { conteos[categoryID] ?? 0 }

    var duplicateCount: Int {
        if let d = cacheDuplicados { return d }
        let d = items.reduce(0) { $0 + ($1.isDuplicate ? 1 : 0) }
        cacheDuplicados = d
        return d
    }

    /// Solo donde de verdad hagan falta los elementos; para contar, `pendingCount`.
    var pending: [MediaItem] { items.filter { $0.decision == nil } }

    func category(_ id: Int) -> Category? { categories.first { $0.id == id } }

    /// La tecla de una categoría es su POSICIÓN en la sesión (1, 2, 3…), no su
    /// id. Así una sesión con dos clasificaciones se maneja con 1 y 2, aunque
    /// por dentro sean «Persona 1» (1) y «Descartar» (4).
    func tecla(de cat: Category) -> Int {
        (categories.firstIndex { $0.id == cat.id } ?? 0) + 1
    }

    /// La categoría que hay en esa posición, si existe.
    func categoria(enTecla n: Int) -> Category? {
        categories.indices.contains(n - 1) ? categories[n - 1] : nil
    }

    /// Cambia las clasificaciones de la sesión abierta. Nunca quita una que ya
    /// se haya usado: perder la categoría dejaría esas decisiones sin sentido.
    func setCategories(_ nuevas: [Category]) -> [String] {
        var finales = nuevas
        var conservadas: [String] = []
        for c in categories where !nuevas.contains(where: { $0.id == c.id }) {
            if count(for: c.id) > 0 {
                finales.append(c)
                conservadas.append("\(c.name) (\(count(for: c.id)) ya clasificadas)")
            }
        }
        categories = finales.sorted { a, b in
            let ia = Category.catalogo.firstIndex { $0.id == a.id } ?? 99
            let ib = Category.catalogo.firstIndex { $0.id == b.id } ?? 99
            return ia < ib
        }
        save()
        return conservadas
    }

    // MARK: - Pool

    func addToPool(_ urls: [URL]) {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        scanMessage = "Buscando archivos…"

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                MediaScanner.expand(urls)
            }.value

            let existing = Set(items.map(\.url.standardizedFileURL))
            let fresh = found.filter { !existing.contains($0.standardizedFileURL) }

            if fresh.isEmpty {
                scanMessage = found.isEmpty
                    ? "No se encontró ningún archivo compatible."
                    : "Esos archivos ya estaban en el pool."
                isScanning = false
                return
            }

            scanMessage = "Leyendo metadatos de \(fresh.count) archivos…"
            var newItems = await MediaScanner.makeItems(from: fresh) { [weak self] done, total in
                Task { @MainActor in
                    self?.scanProgress = total > 0 ? Double(done) / Double(total) : 0
                }
            }

            scanMessage = "Comprobando duplicados…"
            scanProgress = 0
            var combined = items + newItems
            await Task.detached(priority: .userInitiated) { [combined] in
                var copy = combined
                MediaScanner.markDuplicates(&copy) { done, total in
                    Task { @MainActor in
                        self.scanProgress = total > 0 ? Double(done) / Double(total) : 1
                    }
                }
                let result = copy
                await MainActor.run { self.items = result }
            }.value

            newItems = []
            combined = []
            scanMessage = ""
            isScanning = false
            if currentIndex >= items.count { currentIndex = max(0, items.count - 1) }
            jumpToFirstPending()
            save()
            sincronizarPendientes()
        }
    }

    func removeFromPool(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        history.removeAll { ids.contains($0.itemID) }
        if currentIndex >= items.count { currentIndex = max(0, items.count - 1) }
        save()
    }

    func clearPool() {
        items = []
        history = []
        currentIndex = 0
        save()
    }

    // MARK: - Navegación

    func jumpToFirstPending() {
        if let i = items.firstIndex(where: { $0.decision == nil }) { currentIndex = i }
    }

    func advance() {
        // siguiente sin clasificar a partir del actual; si no hay, hacia atrás
        if let i = items.indices.dropFirst(currentIndex + 1).first(where: { items[$0].decision == nil }) {
            currentIndex = i
        } else if let i = items.firstIndex(where: { $0.decision == nil }) {
            currentIndex = i
        } else if currentIndex < items.count - 1 {
            currentIndex += 1
        }
    }

    func step(_ delta: Int) {
        let n = items.count
        guard n > 0 else { return }
        currentIndex = min(max(0, currentIndex + delta), n - 1)
    }

    // MARK: - Clasificar

    func classify(_ categoryID: Int) {
        guard let cat = category(categoryID),
              items.indices.contains(currentIndex) else { return }
        let idx = currentIndex
        let item = items[idx]

        var created: [URL] = []
        for folder in cat.folders {
            do {
                let dir = destinationRoot.appendingPathComponent(folder)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let dest = try copy(item.url, into: dir) {
                    // la rotación se aplica solo a la copia; el original ni se toca
                    if item.rot != 0 {
                        Rotator.apply(item.rot, to: dest, kind: item.kind)
                    }
                    created.append(dest)
                }
            } catch {
                lastError = "No se pudo copiar «\(item.name)» a \(folder): \(error.localizedDescription)"
                return
            }
        }

        // ya clasificada: sale del montón de pendientes
        var pendienteBorrada: URL?
        let enPendientes = carpetaPendientes.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: enPendientes.path) {
            try? FileManager.default.removeItem(at: enPendientes)
            pendienteBorrada = enPendientes
        }

        items[idx].decision = categoryID
        history.append(Decision(itemID: item.id, itemIndex: idx,
                                categoryID: categoryID, createdFiles: created,
                                pendienteBorrada: pendienteBorrada))
        advance()
        save()
    }

    // MARK: - Pendientes

    var carpetaPendientes: URL {
        destinationRoot.appendingPathComponent(Rutas.pendientes)
    }

    /// Deja «Pendientes» con exactamente lo que falta por clasificar: clona lo que
    /// no esté y borra lo que ya sobre. Los clones de APFS son instantáneos y no
    /// ocupan disco, así que tener ahí 20 GB no cuesta nada.
    func sincronizarPendientes() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        scanMessage = "Preparando la carpeta Pendientes…"

        let dir = carpetaPendientes
        let quedan = items.filter { $0.decision == nil }

        // Reparto de nombres hecho a mano y SIEMPRE igual. Hay fotos distintas que
        // se llaman igual (una recibida y otra enviada el mismo día): a la segunda
        // hay que darle otro nombre, no saltársela, y el reparto debe salir idéntico
        // en cada pasada o cada sincronización crearía copias nuevas.
        var asignado: [String: MediaItem] = [:]
        for it in quedan {
            var nombre = it.name
            if asignado[nombre] != nil {
                let base = (nombre as NSString).deletingPathExtension
                let ext = (nombre as NSString).pathExtension
                var k = 2
                while asignado["\(base)-\(k).\(ext)"] != nil { k += 1 }
                nombre = "\(base)-\(k).\(ext)"
            }
            asignado[nombre] = it
        }

        Task {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // sobra lo que ya no toque estar
            let hay = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in hay where !n.hasPrefix(".") && asignado[n] == nil {
                try? fm.removeItem(at: dir.appendingPathComponent(n))
            }

            var hechos = 0
            for (nombre, it) in asignado {
                let destino = dir.appendingPathComponent(nombre)
                let tam = (try? destino.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if tam == nil || Int64(tam!) != it.fileSize {
                    try? fm.removeItem(at: destino)
                    if clonefile(it.url.path, destino.path, 0) != 0 {
                        try? fm.copyItem(at: it.url, to: destino)
                    }
                }
                hechos += 1
                if hechos % 500 == 0 {
                    scanProgress = Double(hechos) / Double(max(1, asignado.count))
                    scanMessage = "Pendientes: \(hechos) de \(asignado.count)…"
                    await Task.yield()
                }
            }
            scanMessage = ""
            isScanning = false
        }
    }

    /// Copia conservando fecha y atributos. Si ya existe un archivo idéntico
    /// (mismo nombre y tamaño) no duplica; si el nombre choca, añade sufijo.
    /// No es privada para que las pruebas usen esta misma lógica y no una copia.
    func copy(_ src: URL, into dir: URL) throws -> URL? {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(src.lastPathComponent)

        if fm.fileExists(atPath: dest.path) {
            let a = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let b = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if a == b { return nil }              // ya está, no hacemos nada
            let stem = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            var k = 2
            repeat {
                dest = dir.appendingPathComponent("\(stem)-\(k).\(ext)")
                k += 1
            } while fm.fileExists(atPath: dest.path)
        }

        // clonefile es instantáneo y no ocupa disco; si no puede (otro volumen,
        // disco que no sea APFS), copiamos a la manera tradicional.
        if clonefile(src.path, dest.path, 0) != 0 {
            try fm.copyItem(at: src, to: dest)    // copyItem conserva las fechas
        }
        return dest
    }

    // MARK: - Rotar

    /// Gira la foto actual. Solo apunta los grados: nada se escribe hasta que la
    /// clasificas, y entonces se aplica únicamente a la copia.
    func rotate(_ delta: Int) {
        guard items.indices.contains(currentIndex) else { return }
        items[currentIndex].rotation = (((items[currentIndex].rot + delta) % 360) + 360) % 360
        save()
    }

    // MARK: - Clasificar en lote

    /// Manda varias del pool a una categoría de golpe, sin verlas una a una.
    func classifyBatch(_ ids: Set<UUID>, to categoryID: Int) {
        guard category(categoryID) != nil else { return }
        let guardado = currentIndex
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }),
                  items[i].decision == nil else { continue }
            currentIndex = i
            classify(categoryID)
        }
        currentIndex = min(guardado, max(0, items.count - 1))
        jumpToFirstPending()
        save()
    }

    // MARK: - Ordenar

    enum SortKey: String, CaseIterable, Identifiable {
        case fecha, nombre, tamaño, tipo
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fecha: return "Fecha"
            case .nombre: return "Nombre"
            case .tamaño: return "Tamaño"
            case .tipo: return "Tipo"
            }
        }
    }

    /// Reordena el pool de verdad (no solo la vista), manteniendo dónde estabas.
    func sortPool(by key: SortKey, ascending: Bool) {
        let actual = current?.id
        items.sort { a, b in
            let menor: Bool
            switch key {
            case .fecha: menor = (a.date ?? .distantPast) < (b.date ?? .distantPast)
            case .nombre: menor = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .tamaño: menor = a.fileSize < b.fileSize
            case .tipo:
                menor = a.kind == b.kind
                    ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                    : a.kind == .image
            }
            return ascending ? menor : !menor
        }
        if let actual, let i = items.firstIndex(where: { $0.id == actual }) {
            currentIndex = i
        }
        save()
    }

    // MARK: - Deshacer

    var canUndo: Bool { !history.isEmpty }

    func undo() {
        guard let last = history.popLast() else { return }
        for f in last.createdFiles { try? FileManager.default.removeItem(at: f) }
        if let i = items.firstIndex(where: { $0.id == last.itemID }) {
            items[i].decision = nil
            currentIndex = i
            // vuelve al montón de pendientes
            if last.pendienteBorrada != nil {
                try? FileManager.default.createDirectory(at: carpetaPendientes,
                                                         withIntermediateDirectories: true)
                _ = try? copy(items[i].url, into: carpetaPendientes)
            }
        }
        save()
    }

    // MARK: - Persistencia y sesiones

    private var supportDir: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClasificadorFotos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var sessionsDir: URL {
        let dir = supportDir.appendingPathComponent("Sesiones")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { supportDir.appendingPathComponent("sesiones.json") }
    private var legacyURL: URL { supportDir.appendingPathComponent("sesion.json") }

    private func fileURL(_ id: UUID) -> URL {
        sessionsDir.appendingPathComponent("\(id.uuidString).json")
    }

    /// Sesiones ordenadas por uso más reciente, que es como se quieren ver.
    var sessionsByRecent: [SessionMeta] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeSession: SessionMeta? { sessions.first { $0.id == activeSessionID } }

    // MARK: Guardar / cargar

    /// Guardado diferido. Con 32.000 fotos, codificar la sesión cuesta ~115 ms;
    /// hacerlo en cada tecla congelaba la app. Ahora se agrupan los cambios y se
    /// escribe fuera del hilo principal.
    func save() { programarGuardado(retraso: 1.5) }

    /// Escribe ya y espera a que termine. Obligatorio antes de cambiar de sesión
    /// o de cerrar la app: si no, el guardado diferido se quedaría a medias y se
    /// perderían las últimas decisiones.
    func saveNow() {
        tareaGuardado?.cancel()
        tareaGuardado = nil
        escribirSesion(sincrono: true)
    }

    private func programarGuardado(retraso: Double) {
        actualizarMeta()
        guard tareaGuardado == nil else { return }   // ya hay uno en camino
        tareaGuardado = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(retraso * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.tareaGuardado = nil
            self.escribirSesion()
        }
    }

    /// Deja la ficha de la sesión al día al momento (es barato) para que la lista
    /// y los contadores no esperen al guardado.
    private func actualizarMeta() {
        let meta = SessionMeta(id: activeSessionID, name: sessionName,
                               createdAt: sessionCreatedAt, updatedAt: Date(),
                               itemCount: items.count, pendingCount: pendingCount)
        if let i = sessions.firstIndex(where: { $0.id == activeSessionID }) {
            sessions[i] = meta
        } else {
            sessions.append(meta)
        }
    }

    private func escribirSesion(sincrono: Bool = false) {
        actualizarMeta()
        var state = SessionState(name: sessionName, destinationRoot: destinationRoot,
                                 categories: categories)
        state.id = activeSessionID
        state.createdAt = sessionCreatedAt
        state.updatedAt = Date()
        state.items = items
        state.currentIndex = currentIndex
        state.history = history

        let destino = fileURL(activeSessionID)
        if sincrono {
            let enc = JSONEncoder()
            if let datos = try? enc.encode(state) {
                try? datos.write(to: destino, options: .atomic)
            }
        } else {
            // codificar 32.000 elementos son ~115 ms: fuera del hilo principal
            Task.detached(priority: .utility) {
                let enc = JSONEncoder()      // compacto: la mitad de bytes que con sangrado
                if let datos = try? enc.encode(state) {
                    try? datos.write(to: destino, options: .atomic)
                }
            }
        }
        saveIndex()
    }

    private func saveIndex() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        let idx = SessionIndex(activeID: activeSessionID, sessions: sessions)
        try? enc.encode(idx).write(to: indexURL, options: .atomic)
    }

    func load() {
        if let data = try? Data(contentsOf: indexURL),
           let idx = try? JSONDecoder().decode(SessionIndex.self, from: data),
           !idx.sessions.isEmpty {
            sessions = idx.sessions
            let target = idx.activeID ?? sessionsByRecent.first!.id
            openSession(target, saveCurrentFirst: false)
            return
        }

        // migración: una única sesión del formato antiguo
        if let data = try? Data(contentsOf: legacyURL),
           let old = try? JSONDecoder().decode(SessionState.self, from: data) {
            activeSessionID = old.id
            sessionName = old.name == "Sesión" ? "Sesión inicial" : old.name
            sessionCreatedAt = old.createdAt
            adopt(old)
            save()
            try? FileManager.default.removeItem(at: legacyURL)
            return
        }

        // primer arranque
        startFreshSession(named: "Mi primera sesión")
    }

    private func adopt(_ s: SessionState) {
        // descarta lo que ya no exista en disco
        items = s.items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        categories = s.categories.isEmpty ? Category.defaults : s.categories
        destinationRoot = s.destinationRoot
        history = s.history
        currentIndex = min(max(0, s.currentIndex), max(0, items.count - 1))

        // Las categorías se guardan dentro de cada sesión, así que las de antes
        // de que «Descartar» copiase a algún sitio se quedarían sin carpeta.
        for i in categories.indices where categories[i].folders.isEmpty
            && categories[i].name.lowercased().hasPrefix("descart") {
            categories[i].folders = [Category.carpetaDescartadas]
        }
    }

    private func startFreshSession(named name: String, categorias: [Category]? = nil) {
        activeSessionID = UUID()
        sessionName = name
        sessionCreatedAt = Date()
        destinationRoot = Rutas.carpetaSesion(name)
        if let categorias, !categorias.isEmpty { categories = categorias }
        items = []
        history = []
        currentIndex = 0
        save()
    }

    // MARK: Gestión de sesiones

    func openSession(_ id: UUID, saveCurrentFirst: Bool = true) {
        guard id != activeSessionID || !saveCurrentFirst else { return }
        if saveCurrentFirst { saveNow() }   // cerrar bien la anterior antes de irse

        guard let data = try? Data(contentsOf: fileURL(id)),
              let s = try? JSONDecoder().decode(SessionState.self, from: data) else {
            lastError = "No se pudo abrir esa sesión: falta su archivo."
            sessions.removeAll { $0.id == id }
            saveIndex()
            return
        }
        activeSessionID = s.id
        sessionName = s.name
        sessionCreatedAt = s.createdAt
        adopt(s)
        jumpToFirstPending()
        saveIndex()
    }

    /// Crea una sesión vacía. Hereda la carpeta destino de la actual (lo normal es
    /// querer otro montón de fotos pero las mismas carpetas), y se queda con las
    /// clasificaciones que le pases; si no le pasas ninguna, con las de la actual.
    func newSession(named name: String, categorias: [Category]? = nil) {
        saveNow()
        let limpio = name.trimmingCharacters(in: .whitespacesAndNewlines)
        startFreshSession(named: limpio.isEmpty ? nombreLibre() : limpio,
                          categorias: categorias)
    }

    func renameSession(_ id: UUID, to name: String) {
        let limpio = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return }
        if id == activeSessionID {
            sessionName = limpio
            save()
        } else if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].name = limpio
            if var s = readSession(id) {
                s.name = limpio
                writeSession(s)
            }
            saveIndex()
        }
    }

    /// Duplica el pool y las decisiones en una sesión nueva. Los archivos ya
    /// copiados NO se tocan: solo se duplica el estado de la clasificación.
    func duplicateSession(_ id: UUID) {
        if id == activeSessionID { saveNow() }
        guard var s = readSession(id) else { return }
        s.id = UUID()
        s.name = nombreLibre(base: s.name + " (copia)")
        s.createdAt = Date()
        s.updatedAt = Date()
        writeSession(s)
        sessions.append(SessionMeta(id: s.id, name: s.name, createdAt: s.createdAt,
                                    updatedAt: s.updatedAt, itemCount: s.items.count,
                                    pendingCount: s.items.filter { $0.decision == nil }.count))
        saveIndex()
    }

    /// Borra la sesión. Solo elimina su archivo de estado: ni las fotos del pool
    /// ni las copias ya hechas se tocan.
    func deleteSession(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        sessions.removeAll { $0.id == id }
        if id == activeSessionID {
            if let siguiente = sessionsByRecent.first {
                openSession(siguiente.id, saveCurrentFirst: false)
            } else {
                startFreshSession(named: "Mi primera sesión")
            }
        } else {
            saveIndex()
        }
    }

    private func readSession(_ id: UUID) -> SessionState? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    private func writeSession(_ s: SessionState) {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(s).write(to: fileURL(s.id), options: .atomic)
    }

    /// "Sesión 3" evitando chocar con las que ya existan.
    private func nombreLibre(base: String = "Sesión") -> String {
        let usados = Set(sessions.map(\.name))
        if !usados.contains(base) { return base }
        var n = 2
        while usados.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func revealDestination() {
        try? FileManager.default.createDirectory(at: destinationRoot,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(destinationRoot)
    }
}
