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
        didSet { cacheConteos = nil; cacheDuplicados = nil; cacheIndice = nil }
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
    /// Avisos que no son errores, p. ej. lo que ha arreglado la app al abrir.
    @Published var aviso: String?

    // MARK: - Derivados

    private var cacheConteos: [Int: Int]?
    private var cacheDuplicados: Int?
    private var cacheIndice: [UUID: Int]?
    private var tareaGuardado: Task<Void, Never>?
    /// La tarea larga que lleva ahora el indicador de progreso. Si una vieja
    /// termina tarde, no apaga el indicador de la nueva.
    private var tareaEscaneo: UUID?

    /// Posición de cada elemento en el pool por su id. El historial apunta por id
    /// y buscarlos uno a uno entre 32.000 en cada pintada sería lento.
    func posicion(de id: UUID) -> Int? {
        if cacheIndice == nil {
            var d: [UUID: Int] = [:]
            d.reserveCapacity(items.count)
            for (i, it) in items.enumerated() { d[it.id] = i }
            cacheIndice = d
        }
        return cacheIndice?[id]
    }

    /// Lo ya clasificado, lo último primero. Sale del historial, que guarda una
    /// entrada por foto y en el orden en que las fuiste clasificando.
    var clasificadas: [(decision: Decision, item: MediaItem)] {
        history.reversed().compactMap { d in
            guard let i = posicion(de: d.itemID), items[i].decision != nil else { return nil }
            return (d, items[i])
        }
    }

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

        let sesion = activeSessionID
        let tarea = UUID()
        tareaEscaneo = tarea
        Task {
            defer {
                if tareaEscaneo == tarea {
                    tareaEscaneo = nil; isScanning = false; scanMessage = ""
                }
            }
            let found = await Task.detached(priority: .userInitiated) {
                MediaScanner.expand(urls).map(Rutas.normal)
            }.value

            // Sin repetidos: ni los que ya están ni los que vienen dos veces
            // (arrastrar una carpeta y además un archivo de dentro).
            var vistos = Set(items.map(\.url.standardizedFileURL.path))
            let fresh = found.filter { vistos.insert($0.standardizedFileURL.path).inserted }

            if fresh.isEmpty {
                lastError = found.isEmpty
                    ? "No se encontró ningún archivo compatible."
                    : "Esos archivos ya estaban en el pool."
                return
            }

            scanMessage = "Leyendo metadatos de \(fresh.count) archivos…"
            var newItems = await MediaScanner.makeItems(from: fresh) { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.tareaEscaneo == tarea else { return }
                    self.scanProgress = total > 0 ? Double(done) / Double(total) : 0
                }
            }

            scanMessage = "Comprobando duplicados…"
            scanProgress = 0
            let combined = items + newItems
            let marcadas = await Task.detached(priority: .userInitiated) { [combined] in
                var copy = combined
                MediaScanner.markDuplicates(&copy) { done, total in
                    Task { @MainActor in
                        guard self.tareaEscaneo == tarea else { return }
                        self.scanProgress = total > 0 ? Double(done) / Double(total) : 1
                    }
                }
                return copy
            }.value

            // Mientras se buscaban duplicados has podido seguir clasificando (o
            // la app recuperando fotos): no se pisa el pool con la foto vieja,
            // solo se le añaden las nuevas y las marcas de duplicado.
            guard activeSessionID == sesion else { return }
            var marca: [UUID: (String?, String?)] = [:]
            for it in marcadas { marca[it.id] = (it.contentHash, it.duplicateOfName) }
            var pool = items
            for i in pool.indices {
                if let m = marca[pool[i].id] {
                    pool[i].contentHash = m.0
                    pool[i].duplicateOfName = m.1
                }
            }
            let nuevasIDs = Set(newItems.map(\.id))
            pool.append(contentsOf: marcadas.filter { nuevasIDs.contains($0.id) })
            items = pool

            newItems = []
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

    /// Clasifica la actual. Si ya estaba clasificada y pulsas otra categoría, la
    /// cambia (antes la dejaba copiada en las dos carpetas).
    func classify(_ categoryID: Int) {
        guard let cat = category(categoryID),
              items.indices.contains(currentIndex) else { return }
        let idx = currentIndex

        if let anterior = items[idx].decision {
            if anterior != categoryID { cambiarDecision(items[idx].id, a: categoryID) }
            advance()
            save()
            return
        }

        let item = items[idx]
        let r: (creados: [URL], destinos: [URL])
        do {
            r = try copiar(item, a: cat)
        } catch {
            lastError = "No se pudo copiar «\(item.name)»: \(error.localizedDescription)"
            return
        }

        // Ya clasificada: sale del montón de pendientes. Solo se borra si es
        // ella misma y ya tiene otro sitio donde vivir, o si es SU clon (mismo
        // contenido, byte a byte) y no lo usa ninguna otra foto del pool.
        let fm = FileManager.default
        var pendienteBorrada: URL?
        let enPendientes = estaEnPendientes(item.url)
            ? item.url : carpetaPendientes.appendingPathComponent(item.name)
        if fm.fileExists(atPath: enPendientes.path) {
            let puedeIrse = !esDeOtra(enPendientes, salvo: item.id) && (mismaRuta(enPendientes, item.url)
                ? r.destinos.contains { fm.fileExists(atPath: $0.path) }
                : mismoContenido(enPendientes, item.url))
            if puedeIrse {
                try? fm.removeItem(at: enPendientes)
                pendienteBorrada = enPendientes
            }
        }

        items[idx].decision = categoryID
        seguirAlArchivo(idx, destinos: r.destinos, creados: r.creados)
        history.removeAll { $0.itemID == item.id }   // una entrada por foto
        // `destinos`, no solo lo creado: si reaprovechó una idéntica que ya
        // estaba, queda apuntada como suya también. Así, mientras la usen dos
        // fotos, ninguna de las dos la borra (`esDeOtra`).
        history.append(Decision(itemID: item.id, itemIndex: idx,
                                categoryID: categoryID, createdFiles: r.destinos,
                                pendienteBorrada: pendienteBorrada, fecha: Date()))
        advance()
        save()
    }

    /// Cambia de categoría una foto ya clasificada: la copia en sus carpetas nuevas
    /// y quita las copias de la categoría vieja. Primero copia y luego borra, así
    /// que si algo falla a medias la foto sigue donde estaba.
    func cambiarDecision(_ id: UUID, a categoryID: Int) {
        guard let idx = posicion(de: id), let anterior = items[idx].decision,
              anterior != categoryID, let cat = category(categoryID) else { return }
        guard moverDecision(idx, a: cat) else { return }
        if let e = history.lastIndex(where: { $0.itemID == id }) {
            // pila: cada ⌘Z deshace UN cambio, en orden inverso
            history[e].anteriores = (history[e].anteriores ?? []) + [anterior]
            history[e].cambiada = Date()
        }
        save()
    }

    /// Mueve las copias de una foto clasificada a otra categoría y deja su
    /// entrada del historial al día. No toca la pila de cambios: eso es cosa de
    /// quien llama.
    @discardableResult
    private func moverDecision(_ idx: Int, a cat: Category) -> Bool {
        let fm = FileManager.default
        asegurarArchivo(idx)
        let item = items[idx]
        let e = history.lastIndex { $0.itemID == item.id }
        let viejos = e.map { history[$0].createdFiles } ?? []

        let r: (creados: [URL], destinos: [URL])
        do {
            // con un giro nuevo pendiente, las copias viejas no valen: todas nuevas
            r = try copiar(item, a: cat, propias: item.rot != 0 ? [] : viejos)
        } catch {
            lastError = "No se pudo mover «\(item.name)» a \(cat.name): \(error.localizedDescription)"
            return false
        }

        // Las copias viejas que la categoría nueva también usa (p. ej. de
        // «Persona 1» a «Las dos», que también copia en Persona 1/) se quedan y
        // pasan a ser suyas; el resto se borra. Pero el archivo de la foto solo
        // se borra si le queda otro sitio: con una categoría que no copia a
        // ningún lado, se queda donde está.
        let destinos = Set(r.destinos.map(\.standardizedFileURL))
        let leQuedaSitio = r.destinos.contains { fm.fileExists(atPath: $0.path) }
        var creados = r.destinos    // también las idénticas que ya estaban: compartidas
        for f in viejos {
            let seQueda = destinos.contains(f.standardizedFileURL)
                || (mismaRuta(f, item.url) && !leQuedaSitio)
            if seQueda {
                if !creados.contains(where: { mismaRuta($0, f) }) { creados.append(f) }
            } else {
                borrarCopia(f, de: item.id)
            }
        }

        items[idx].decision = cat.id
        seguirAlArchivo(idx, destinos: r.destinos, creados: creados)
        if let e {
            history[e].categoryID = cat.id
            history[e].createdFiles = creados
        } else {
            history.append(Decision(itemID: item.id, itemIndex: idx, categoryID: cat.id,
                                    createdFiles: creados, fecha: Date()))
        }
        return true
    }

    /// Devuelve una foto clasificada al montón de pendientes: vuelve a
    /// «Pendientes/» y se borran las copias que había hecho la app.
    func devolverAPendientes(_ id: UUID) {
        guard let i = posicion(de: id), items[i].decision != nil else { return }
        let fm = FileManager.default
        asegurarArchivo(i)
        let item = items[i]
        guard fm.fileExists(atPath: item.url.path) else {
            lastError = "No encuentro ningún archivo de «\(item.name)»: no se toca nada."
            return
        }
        let entrada = history.last { $0.itemID == id }
        let creados = entrada?.createdFiles ?? []
        let laFotoEsUnaCopia = creados.contains { mismaRuta($0, item.url) }

        // Primero se pone a salvo en «Pendientes» y DESPUÉS se borran las copias:
        // si la foto del pool es una de ellas, borrarla antes la perdería.
        var enPendientes: URL?
        if estaEnPendientes(item.url) {
            enPendientes = item.url
        } else if entrada?.pendienteBorrada != nil || laFotoEsUnaCopia {
            do {
                try fm.createDirectory(at: carpetaPendientes, withIntermediateDirectories: true)
                enPendientes = try copy(item.url, into: carpetaPendientes)
                    ?? carpetaPendientes.appendingPathComponent(item.url.lastPathComponent)
            } catch {
                if laFotoEsUnaCopia {
                    lastError = "No se pudo devolver «\(item.name)» a Pendientes: \(error.localizedDescription)"
                    return
                }
            }
        }

        for f in creados {
            if let p = enPendientes, mismaRuta(p, f) { continue }
            if mismaRuta(f, item.url) && enPendientes == nil { continue }   // su único sitio
            borrarCopia(f, de: id)
        }
        if let p = enPendientes, !fm.fileExists(atPath: item.url.path) {
            items[i].url = p
        }
        items[i].decision = nil
        history.removeAll { $0.itemID == id }
        save()
    }

    /// Copia la foto en las carpetas de `cat`. Devuelve, por carpeta, dónde ha
    /// quedado (`destinos`) y cuáles se han creado ahora (`creados`; si ya había
    /// una idéntica byte a byte no se crea otra). Si falla a medias —también si
    /// no se puede aplicar el giro—, borra lo que haya creado en este intento y
    /// lanza el error: o se copia entera o nada.
    /// `propias`: copias que esta foto ya tiene (al cambiarla de categoría). Si
    /// ya tiene una en esa carpeta se reaprovecha tal cual, con su giro.
    private func copiar(_ item: MediaItem, a cat: Category,
                        propias: [URL] = []) throws -> (creados: [URL], destinos: [URL]) {
        let fm = FileManager.default
        var creados: [URL] = []
        var destinos: [URL] = []
        do {
            for folder in cat.folders {
                let dir = destinationRoot.appendingPathComponent(folder)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if let suya = propias.first(where: {
                    mismaRuta($0.deletingLastPathComponent(), dir) && fm.fileExists(atPath: $0.path)
                }) {
                    destinos.append(suya)
                    continue
                }
                if let dest = try copy(item.url, into: dir, siempreNueva: item.rot != 0) {
                    creados.append(dest)
                    // la rotación se aplica solo a la copia; el original ni se toca
                    if item.rot != 0, !Rotator.apply(item.rot, to: dest, kind: item.kind) {
                        throw NSError(domain: "Clasificador", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "no se pudo girar la copia"])
                    }
                    destinos.append(dest)
                } else {
                    destinos.append(dir.appendingPathComponent(item.url.lastPathComponent))
                }
            }
        } catch {
            for f in creados { try? fm.removeItem(at: f) }
            throw error
        }
        return (creados, destinos)
    }

    /// Si el archivo al que apuntaba la foto ya no existe (porque era el de
    /// «Pendientes» y salió de ahí, o una copia que se acaba de borrar), la foto
    /// pasa a apuntar a su copia nueva. Sin esto desaparecía del pool al volver
    /// a abrir la app, y con ella tu historial.
    private func seguirAlArchivo(_ idx: Int, destinos: [URL], creados: [URL]) {
        guard !FileManager.default.fileExists(atPath: items[idx].url.path),
              let nuevo = destinos.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return }
        items[idx].url = nuevo
        // la copia ya lleva el giro aplicado: no hay que volver a girarla
        if creados.contains(where: { mismaRuta($0, nuevo) }) {
            items[idx].rotation = nil
        }
    }

    /// Si el original desapareció (lo moviste, se desmontó el disco…) pero
    /// queda alguna de sus copias, la foto pasa a apuntar a ella. Así se puede
    /// seguir cambiando o devolviendo sin perder la única copia que queda.
    private func asegurarArchivo(_ idx: Int) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: items[idx].url.path),
              let copia = history.last(where: { $0.itemID == items[idx].id })?
                .createdFiles.first(where: { fm.fileExists(atPath: $0.path) })
        else { return }
        items[idx].url = copia
        items[idx].rotation = nil
    }

    /// Borra una copia hecha por la app, salvo que otra foto del pool la use
    /// como suya (su archivo o una de sus copias).
    private func borrarCopia(_ f: URL, de id: UUID) {
        guard !esDeOtra(f, salvo: id) else { return }
        try? FileManager.default.removeItem(at: f)
    }

    private func esDeOtra(_ f: URL, salvo id: UUID) -> Bool {
        items.contains { $0.id != id && mismaRuta($0.url, f) }
            || history.contains { $0.itemID != id && $0.createdFiles.contains { mismaRuta($0, f) } }
    }

    private func mismaRuta(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// Mismo archivo o mismo contenido byte a byte. El nombre y el tamaño no
    /// bastan: hay fotos distintas que se llaman igual.
    private func mismoContenido(_ a: URL, _ b: URL) -> Bool {
        mismaRuta(a, b) || FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }

    private func estaEnPendientes(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path
            == carpetaPendientes.standardizedFileURL.path
    }

    // MARK: - Pendientes

    var carpetaPendientes: URL {
        destinationRoot.appendingPathComponent(Rutas.pendientes)
    }

    /// Deja «Pendientes» con lo que falta por clasificar: clona lo que no esté y
    /// quita lo que ya sobre. Los clones de APFS son instantáneos y no ocupan
    /// disco, así que tener ahí 20 GB no cuesta nada.
    ///
    /// Lo que no se sabe de quién es NO se toca: solo se quita un archivo de
    /// Pendientes si es idéntico a una foto que sigue a salvo en otro sitio, y
    /// nunca se pisa un archivo que no sea el clon de la suya. Antes, vaciar el
    /// pool y añadir cualquier cosa borraba todo Pendientes, que en algunas
    /// sesiones es el único sitio donde están esas fotos.
    func sincronizarPendientes() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        scanMessage = "Preparando la carpeta Pendientes…"
        let tarea = UUID()
        tareaEscaneo = tarea

        let dir = carpetaPendientes
        let quedan = items.filter { $0.decision == nil }

        // Las fotos del pool que YA viven en «Pendientes» (pasa cuando el pool se
        // llenó desde esa carpeta) son el único sitio donde está esa foto en la
        // sesión: su nombre es suyo, no se borran y no se clonan sobre sí mismas.
        var asignado: [String: MediaItem] = [:]
        var protegidos = Set<String>()
        for it in items where estaEnPendientes(it.url) {
            protegidos.insert(it.url.lastPathComponent)
            if it.decision == nil { asignado[it.url.lastPathComponent] = it }
        }

        // Reparto de nombres hecho a mano y SIEMPRE igual. Hay fotos distintas que
        // se llaman igual (una recibida y otra enviada el mismo día): a la segunda
        // hay que darle otro nombre, no saltársela, y el reparto debe salir idéntico
        // en cada pasada o cada sincronización crearía copias nuevas.
        for it in quedan where !estaEnPendientes(it.url) {
            var nombre = it.name
            if asignado[nombre] != nil || protegidos.contains(nombre) {
                let base = (nombre as NSString).deletingPathExtension
                let ext = (nombre as NSString).pathExtension
                var k = 2
                while asignado["\(base)-\(k).\(ext)"] != nil
                        || protegidos.contains("\(base)-\(k).\(ext)") { k += 1 }
                nombre = "\(base)-\(k).\(ext)"
            }
            asignado[nombre] = it
        }

        // Dónde más hay una foto con cada nombre (fuera de Pendientes): sirve
        // para saber si lo que sobra en Pendientes es solo un clon prescindible.
        var gemelas: [String: [URL]] = [:]
        for it in items where !estaEnPendientes(it.url) {
            gemelas[it.url.lastPathComponent, default: []].append(it.url)
        }
        for d in history {
            for f in d.createdFiles { gemelas[f.lastPathComponent, default: []].append(f) }
            if let p = d.pendienteBorrada, let i = posicion(de: d.itemID) {
                gemelas[p.lastPathComponent, default: []].append(items[i].url)
            }
        }

        Task {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // sobra lo que ya no toque estar… si de verdad está a salvo en otro sitio
            var conservados = 0
            let hay = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in hay where !n.hasPrefix(".") && asignado[n] == nil && !protegidos.contains(n) {
                let f = dir.appendingPathComponent(n)
                let aSalvo = (gemelas[n] ?? []).contains { g in
                    !mismaRuta(g, f) && fm.fileExists(atPath: g.path) && mismoContenido(g, f)
                }
                if aSalvo { try? fm.removeItem(at: f) } else { conservados += 1 }
            }

            var hechos = 0
            for (nombre, it) in asignado {
                let destino = dir.appendingPathComponent(nombre)
                if destino.standardizedFileURL == it.url.standardizedFileURL {
                    hechos += 1
                    continue   // ya está aquí: es ella misma
                }
                if !fm.fileExists(atPath: destino.path) {
                    if clonefile(it.url.path, destino.path, 0) != 0 {
                        try? fm.copyItem(at: it.url, to: destino)
                    }
                } else if !esSuClon(destino, de: it.url) {
                    conservados += 1   // hay otra cosa con ese nombre: no se pisa
                }
                hechos += 1
                if hechos % 500 == 0 {
                    scanProgress = Double(hechos) / Double(max(1, asignado.count))
                    scanMessage = "Pendientes: \(hechos) de \(asignado.count)…"
                    await Task.yield()
                }
            }
            if tareaEscaneo == tarea {
                tareaEscaneo = nil; scanMessage = ""; isScanning = false
            }
            if conservados > 0 {
                aviso = "En Pendientes hay \(conservados) archivos que no son clones de ninguna foto del pool. No se han tocado, por si son la única copia de algo."
            }
        }
    }

    /// Un clon conserva tamaño y fecha de modificación del original: con eso
    /// basta para no leer 20 GB en cada sincronización, y si no cuadra, por
    /// contenido.
    private func esSuClon(_ f: URL, de original: URL) -> Bool {
        let k: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let a = try? f.resourceValues(forKeys: k),
              let b = try? original.resourceValues(forKeys: k),
              a.fileSize == b.fileSize else { return false }
        return a.contentModificationDate == b.contentModificationDate || mismoContenido(f, original)
    }

    /// Copia conservando fecha y atributos. Si ya existe un archivo idéntico
    /// (mismo nombre y mismo contenido) no duplica; si el nombre choca, añade sufijo.
    /// No es privada para que las pruebas usen esta misma lógica y no una copia.
    /// `siempreNueva`: aunque haya una idéntica, crea otra (con sufijo). Hace
    /// falta cuando la copia se va a girar: la que ya hay no lleva el giro.
    func copy(_ src: URL, into dir: URL, siempreNueva: Bool = false) throws -> URL? {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(src.lastPathComponent)

        if fm.fileExists(atPath: dest.path) {
            if src.standardizedFileURL.path == dest.standardizedFileURL.path && !siempreNueva { return nil }
            let a = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let b = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            // ya está, no hacemos nada. Nombre y tamaño no bastan para darla por
            // la misma: se comprueba el contenido (solo cuando coinciden ambos).
            if !siempreNueva && a == b && fm.contentsEqual(atPath: src.path, andPath: dest.path) { return nil }
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

    /// Deshace lo ÚLTIMO que hiciste: si fue clasificar, la foto vuelve a
    /// pendientes; si fue cambiarla de categoría, vuelve a la que tenía justo
    /// antes (A→B→C: ⌘Z a B, otro ⌘Z a A).
    /// Las decisiones antiguas no traen fecha: entre ellas manda el orden.
    func undo() {
        guard let k = history.indices.max(by: { a, b in
            let fa = history[a].ultimoCambio, fb = history[b].ultimoCambio
            return fa != fb ? fa < fb : a < b
        }) else { return }
        let entrada = history[k]
        guard let i = posicion(de: entrada.itemID), items[i].decision != nil else {
            history.remove(at: k)   // apunta a algo que ya no está en el pool
            save()
            return
        }
        if var pila = entrada.anteriores, let previa = pila.popLast(), let cat = category(previa) {
            if moverDecision(i, a: cat), let e = history.lastIndex(where: { $0.itemID == entrada.itemID }) {
                history[e].anteriores = pila.isEmpty ? nil : pila
                // mientras queden cambios por deshacer, sigue siendo lo último
                if pila.isEmpty { history[e].cambiada = nil }
            }
        } else {
            devolverAPendientes(entrada.itemID)
        }
        currentIndex = i
        save()
    }

    // MARK: - Persistencia y sesiones

    /// `CLASIFICADOR_SOPORTE` permite a las pruebas trabajar en una carpeta
    /// aparte sin tocar las sesiones de verdad.
    private var supportDir: URL {
        let dir = ProcessInfo.processInfo.environment["CLASIFICADOR_SOPORTE"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default
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
        // Compacto: la mitad de bytes que con sangrado. Devuelve el error, si hubo.
        let escribir = { () -> String? in
            do {
                let datos = try JSONEncoder().encode(state)
                try datos.write(to: destino, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        // Todo pasa por la misma cola, en orden. Antes cada guardado iba por su
        // cuenta y uno viejo podía acabar después que uno nuevo y pisarlo.
        if sincrono {
            if let fallo = Self.colaGuardado.sync(execute: escribir) {
                lastError = "No se pudo guardar la sesión: \(fallo)"
            }
        } else {
            // codificar 32.000 elementos son ~115 ms: fuera del hilo principal
            Self.colaGuardado.async {
                if let fallo = escribir() {
                    Task { @MainActor [weak self] in
                        self?.lastError = "No se pudo guardar la sesión: \(fallo)"
                    }
                }
            }
        }
        saveIndex()
    }

    private static let colaGuardado = DispatchQueue(label: "clasificador.guardado", qos: .utility)

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
        categories = s.categories.isEmpty ? Category.defaults : s.categories
        // Todas las rutas con los enlaces resueltos: si la misma foto llegara por
        // dos caminos (p. ej. /tmp y /private/tmp) parecerían dos archivos y la
        // app podría borrar uno creyendo que es otra copia.
        destinationRoot = Rutas.normal(s.destinationRoot)
        var pool = s.items
        for i in pool.indices { pool[i].url = Rutas.normal(pool[i].url) }
        items = pool
        var hist = s.history
        for k in hist.indices {
            hist[k].createdFiles = hist[k].createdFiles.map(Rutas.normal)
            hist[k].pendienteBorrada = hist[k].pendienteBorrada.map(Rutas.normal)
        }
        history = hist

        // Las categorías se guardan dentro de cada sesión, así que las de antes
        // de que «Descartar» copiase a algún sitio se quedarían sin carpeta.
        for i in categories.indices where categories[i].folders.isEmpty
            && categories[i].name.lowercased().hasPrefix("descart") {
            categories[i].folders = [Category.carpetaDescartadas]
        }

        let (perdidas, cambios) = repararAlAbrir()
        currentIndex = min(max(0, s.currentIndex), max(0, items.count - 1))
        if cambios { save() }
        if !perdidas.isEmpty { recuperar(perdidas) }
    }

    // MARK: Reparación al abrir

    /// Pone en orden una sesión recién abierta. Arregla lo que dejaban las
    /// versiones anteriores, que al clasificar una foto que vivía en «Pendientes»
    /// la sacaban de ahí y la perdían del pool la siguiente vez que se abría la
    /// app: tu historial parecía vacío aunque las copias seguían en sus carpetas.
    ///
    /// Regla de oro: aquí NO se borra nada que pueda ser la única copia de algo.
    /// Cada archivo lo reclama como mucho una foto, y solo se borra una copia
    /// sobrante si es idéntica, byte a byte, al archivo que la foto conserva.
    ///
    /// Devuelve las decisiones cuya foto hay que volver a meter en el pool (eso
    /// se hace aparte, porque hay que leer sus datos) y si ha cambiado algo.
    private func repararAlAbrir() -> (perdidas: [(Decision, URL)], cambios: Bool) {
        let fm = FileManager.default
        var cambios = false
        var sobrantes: [(archivo: URL, de: UUID)] = []

        // 1. Una entrada por foto. Antes, volver a pulsar una tecla sobre una ya
        //    clasificada añadía otra entrada y dejaba la copia vieja en la
        //    carpeta de la primera categoría: la foto acababa en las dos.
        var ultima: [UUID: Int] = [:]
        for (k, d) in history.enumerated() { ultima[d.itemID] = k }
        if ultima.count < history.count {
            var previas: [UUID: [Decision]] = [:]
            for (k, d) in history.enumerated() where ultima[d.itemID] != k {
                previas[d.itemID, default: []].append(d)
            }
            var unidas: [Decision] = []
            for (k, d) in history.enumerated() where ultima[d.itemID] == k {
                var final = d
                // manda lo que diga la foto, que es lo último que se eligió
                if let i = posicion(de: d.itemID), let dec = items[i].decision {
                    final.categoryID = dec
                }
                let suyas = Set(category(final.categoryID)?.folders ?? [])
                for p in previas[d.itemID] ?? [] {
                    final.pendienteBorrada = final.pendienteBorrada ?? p.pendienteBorrada
                    if let f = p.fecha, f < (final.fecha ?? .distantFuture) { final.fecha = f }
                    for f in p.createdFiles {
                        let carpeta = f.deletingLastPathComponent().lastPathComponent
                        if suyas.contains(carpeta) {
                            if !final.createdFiles.contains(f) { final.createdFiles.append(f) }
                        } else {
                            sobrantes.append((f, d.itemID))
                        }
                    }
                }
                unidas.append(final)
            }
            history = unidas
            cambios = true
        }

        // De quién es cada archivo: UN dueño. Primero, lo que ya existe donde
        // dice (el archivo de cada foto, luego sus copias); así lo que se busque
        // por nombre no puede quitárselo a nadie, y si dos decisiones viejas
        // apuntan al mismo archivo, se lo queda la primera.
        var dueño: [String: UUID] = [:]
        func ruta(_ u: URL) -> String { u.standardizedFileURL.path }
        func reclamar(_ u: URL, para id: UUID) -> Bool {
            let r = ruta(u)
            if let d = dueño[r] { return d == id }
            dueño[r] = id
            return true
        }
        func soltar(_ u: URL, de id: UUID) { if dueño[ruta(u)] == id { dueño[ruta(u)] = nil } }
        for it in items where fm.fileExists(atPath: it.url.path) { _ = reclamar(it.url, para: it.id) }
        for k in history.indices {
            let id = history[k].itemID
            let suyas = history[k].createdFiles.filter { f in
                !fm.fileExists(atPath: f.path) || reclamar(f, para: id)
            }
            if suyas.count != history[k].createdFiles.count {
                history[k].createdFiles = suyas      // eran de otra: no las borrará nunca
                cambios = true
            }
        }
        sobrantes = sobrantes.filter { !fm.fileExists(atPath: $0.archivo.path) || reclamar($0.archivo, para: $0.de) }

        /// Busca un archivo con ese nombre en esa carpeta de la sesión, si no es de otra.
        func libre(_ carpeta: String, _ nombre: String, para id: UUID) -> URL? {
            let u = destinationRoot.appendingPathComponent(carpeta).appendingPathComponent(nombre)
            guard fm.fileExists(atPath: u.path), reclamar(u, para: id) else { return nil }
            return u
        }

        // 2. Rutas de copias que se movieron (p. ej. al reorganizar las carpetas
        //    el 8-ago): si no existe donde dice, se busca con su mismo nombre en
        //    la carpeta homónima de esta sesión, si nadie más la reclama.
        for k in history.indices {
            let arregladas = history[k].createdFiles.map { f -> URL in
                if fm.fileExists(atPath: f.path) { return f }
                return libre(f.deletingLastPathComponent().lastPathComponent, f.lastPathComponent,
                             para: history[k].itemID) ?? f
            }
            if arregladas != history[k].createdFiles {
                history[k].createdFiles = arregladas
                cambios = true
            }
        }

        /// Dónde está hoy la foto de una decisión: en una de sus copias o, si se
        /// movieron, por su nombre en las carpetas de su categoría.
        func localizar(_ d: Decision, nombre: String?) -> URL? {
            if let f = d.createdFiles.first(where: { fm.fileExists(atPath: $0.path) }) { return f }
            var nombres = d.createdFiles.map(\.lastPathComponent)
            if let p = d.pendienteBorrada { nombres.append(p.lastPathComponent) }
            if let nombre { nombres.append(nombre) }
            for carpeta in category(d.categoryID)?.folders ?? [] {
                for n in nombres { if let u = libre(carpeta, n, para: d.itemID) { return u } }
            }
            return nil
        }

        // 3. Fotos del pool cuyo archivo ya no está: se buscan donde deberían.
        var entradaDe: [UUID: Decision] = [:]
        for d in history { entradaDe[d.itemID] = d }
        let antes = items.count
        var quedan: [MediaItem] = []
        quedan.reserveCapacity(items.count)
        for var it in items {
            if fm.fileExists(atPath: it.url.path) { quedan.append(it); continue }
            if it.decision != nil, let d = entradaDe[it.id], let u = localizar(d, nombre: it.name) {
                // si es una de sus copias, ya lleva el giro aplicado
                if d.createdFiles.contains(where: { ruta($0) == ruta(u) }) { it.rotation = nil }
                it.url = u
                quedan.append(it)
            } else if it.decision == nil, let u = libre(Rutas.pendientes, it.name, para: it.id) {
                let tam = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if let tam, it.fileSize == 0 || Int64(tam) == it.fileSize {
                    it.url = u
                    quedan.append(it)
                } else {
                    soltar(u, de: it.id)          // no era ella
                }
            }
            // si no aparece por ningún lado, sale del pool, como siempre
        }
        if quedan.count != antes || quedan.map(\.url) != items.map(\.url) { cambios = true }
        items = quedan

        // 4. Decisiones cuya foto ya no está en el pool pero cuyas copias siguen
        //    en las carpetas: se recuperan. Las que no tienen nada se olvidan
        //    (sin borrar ningún archivo).
        let enPool = Set(items.map(\.id))
        var perdidas: [(Decision, URL)] = []
        var vivas: [Decision] = []
        for d in history {
            if enPool.contains(d.itemID) {
                if let i = posicion(de: d.itemID), items[i].decision != nil { vivas.append(d) }
                else { cambios = true }     // la foto está, pero sin clasificar
            } else if let u = localizar(d, nombre: nil) {
                perdidas.append((d, u))
                vivas.append(d)
            } else {
                cambios = true
            }
        }
        history = vivas

        // 5. Fotos clasificadas sin entrada en el historial (sesiones muy viejas
        //    o retocadas a mano): se les crea una para que salgan en el Historial
        //    y se puedan cambiar. Solo se apunta como copia suya un archivo que
        //    sea ella misma o idéntico byte a byte. Van al principio.
        let conEntrada = Set(history.map(\.itemID))
        var sinEntrada: [Decision] = []
        for (i, it) in items.enumerated() {
            guard let dec = it.decision, !conEntrada.contains(it.id) else { continue }
            var d = Decision(itemID: it.id, itemIndex: i, categoryID: dec, createdFiles: [])
            if let copia = localizar(d, nombre: it.name) {
                if mismoContenido(copia, it.url) { d.createdFiles = [copia] }
                else if !mismaRuta(copia, it.url) { soltar(copia, de: it.id) }
            }
            sinEntrada.append(d)
        }
        if !sinEntrada.isEmpty {
            history.insert(contentsOf: sinEntrada, at: 0)
            cambios = true
        }

        // 6. Copias que se quedaron en la carpeta de una categoría que la foto
        //    ya no tiene. Solo se quitan si la foto conserva su archivo bueno y
        //    la sobrante es idéntica a él: si no, se dejan donde están.
        var archivoDe: [UUID: URL] = [:]
        for it in items { archivoDe[it.id] = it.url }
        for (d, u) in perdidas { archivoDe[d.itemID] = u }
        let enUso = Set(items.map { ruta($0.url) })
            .union(history.flatMap(\.createdFiles).map(ruta))
            .union(perdidas.map { ruta($0.1) })
        var quitadas: [String] = []
        for (f, dueña) in sobrantes where fm.fileExists(atPath: f.path) && !enUso.contains(ruta(f)) {
            guard let bueno = archivoDe[dueña], fm.fileExists(atPath: bueno.path),
                  !mismaRuta(bueno, f), mismoContenido(f, bueno) else { continue }
            if (try? fm.removeItem(at: f)) != nil {
                quitadas.append("\(f.deletingLastPathComponent().lastPathComponent)/\(f.lastPathComponent)")
            }
        }
        if !quitadas.isEmpty {
            aviso = "Había \(quitadas.count) fotos copiadas en dos categorías a la vez: las cambiaste de opinión y la versión anterior de la app dejaba las dos copias. Se ha quedado solo la última que elegiste.\n\nQuitadas: " + quitadas.joined(separator: ", ")
        }

        return (perdidas, cambios)
    }

    /// Vuelve a meter en el pool las fotos ya clasificadas que se habían caído,
    /// leyendo de nuevo sus datos (fecha, tamaño, dimensiones) desde la copia.
    private func recuperar(_ perdidas: [(Decision, URL)]) {
        let sesion = activeSessionID
        let tarea = UUID()
        tareaEscaneo = tarea
        isScanning = true
        scanProgress = 0
        scanMessage = "Recuperando \(perdidas.count) fotos que ya habías clasificado…"
        Task {
            let leidas = await MediaScanner.makeItems(from: perdidas.map(\.1)) { [weak self] hechas, total in
                Task { @MainActor in
                    guard let self, self.tareaEscaneo == tarea else { return }
                    self.scanProgress = total > 0 ? Double(hechas) / Double(total) : 0
                }
            }
            // si mientras tanto empezó otra (otra sesión), el indicador es suyo
            defer {
                if tareaEscaneo == tarea {
                    tareaEscaneo = nil; isScanning = false; scanMessage = ""; scanProgress = 0
                }
            }
            // si mientras tanto te has ido a otra sesión, no se mezclan
            guard activeSessionID == sesion else { return }

            var porURL: [String: MediaItem] = [:]
            for it in leidas { porURL[it.url.standardizedFileURL.path] = it }
            var nuevas: [MediaItem] = []
            var usadas = Set<String>()      // un archivo, una foto
            for (d, u) in perdidas where posicion(de: d.itemID) == nil {
                let clave = u.standardizedFileURL.path
                guard !usadas.contains(clave), var it = porURL[clave] else { continue }
                usadas.insert(clave)
                it.id = d.itemID
                it.decision = d.categoryID
                it.rotation = nil
                nuevas.append(it)
            }
            guard !nuevas.isEmpty else { return }
            items.append(contentsOf: nuevas)
            let total = nuevas.count
            aviso = (aviso.map { $0 + "\n\n" } ?? "")
                + "Recuperadas \(total) fotos que ya habías clasificado y no se veían. Están en la pestaña Historial."
            save()
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

    /// Duplica la sesión: pool, decisiones y TAMBIÉN su carpeta de fotos,
    /// clonada con APFS (instantáneo y sin ocupar disco). Así cada sesión es
    /// dueña de sus archivos y cambiar o devolver una foto en una no le rompe
    /// nada a la otra. Los originales que estén fuera de la carpeta se
    /// comparten: la app nunca los toca.
    func duplicateSession(_ id: UUID) {
        guard !isScanning else { return }
        if id == activeSessionID { saveNow() }
        guard var s = readSession(id) else { return }
        let fm = FileManager.default
        let nombre = nombreLibre(base: s.name + " (copia)")
        let vieja = s.destinationRoot.standardizedFileURL
        let junto = vieja.deletingLastPathComponent()
        var nueva = junto.appendingPathComponent(Rutas.carpetaSesion(nombre).lastPathComponent)
        var k = 2
        while fm.fileExists(atPath: nueva.path) {
            nueva = junto.appendingPathComponent(Rutas.carpetaSesion("\(nombre) \(k)").lastPathComponent)
            k += 1
        }

        // ¿La sesión tiene fotos dentro de su carpeta? Si las tiene y la carpeta
        // no está (disco desconectado…), duplicar dejaría la copia rota.
        let dentro = vieja.path + "/"
        let usaCarpeta = s.items.contains { $0.url.standardizedFileURL.path.hasPrefix(dentro) }
            || s.history.contains { $0.createdFiles.contains { $0.standardizedFileURL.path.hasPrefix(dentro) } }

        let tarea = UUID()
        tareaEscaneo = tarea
        isScanning = true
        scanProgress = 0
        scanMessage = "Duplicando «\(s.name)»…"
        Task {
            defer {
                if tareaEscaneo == tarea { tareaEscaneo = nil; isScanning = false; scanMessage = "" }
            }
            let fallo: String? = await Task.detached(priority: .userInitiated) { [vieja, nueva, usaCarpeta] in
                let fm = FileManager.default
                guard fm.fileExists(atPath: vieja.path) else {
                    return usaCarpeta ? "no encuentro la carpeta «\(vieja.path)» (¿disco desconectado?)" : nil
                }
                do {
                    try fm.copyItem(at: vieja, to: nueva)     // en APFS, clona
                    return nil
                } catch {
                    try? fm.removeItem(at: nueva)            // a medias no sirve
                    return error.localizedDescription
                }
            }.value
            if let fallo {
                lastError = "No se pudo duplicar la carpeta de la sesión: \(fallo)"
                return
            }

            // con los enlaces resueltos (p. ej. /tmp es /private/tmp), o una ruta
            // escrita de otra forma no se reconocería como de dentro de la carpeta
            let base = vieja.resolvingSymlinksInPath().path
            let destino = nueva.resolvingSymlinksInPath().path
            func mover(_ u: URL) -> URL {
                let p = u.resolvingSymlinksInPath().path
                guard p.hasPrefix(base + "/") else { return u }
                return URL(fileURLWithPath: destino + p.dropFirst(base.count))
            }
            for i in s.items.indices { s.items[i].url = mover(s.items[i].url) }
            for j in s.history.indices {
                s.history[j].createdFiles = s.history[j].createdFiles.map(mover)
                s.history[j].pendienteBorrada = s.history[j].pendienteBorrada.map(mover)
            }
            s.destinationRoot = nueva
            s.id = UUID()
            s.name = nombre
            s.createdAt = Date()
            s.updatedAt = Date()
            writeSession(s)
            sessions.append(SessionMeta(id: s.id, name: s.name, createdAt: s.createdAt,
                                        updatedAt: s.updatedAt, itemCount: s.items.count,
                                        pendingCount: s.items.filter { $0.decision == nil }.count))
            saveIndex()
        }
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
