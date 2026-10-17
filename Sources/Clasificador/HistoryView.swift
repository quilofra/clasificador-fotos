import AppKit
import SwiftUI

/// Pestaña Historial: todo lo que llevas clasificado, lo último primero. Aquí
/// se ve en qué categoría quedó cada foto y se cambia si te equivocaste.
struct HistoryView: View {
    @EnvironmentObject var store: AppStore

    @State private var filtro: Int?          // id de categoría; nil = todas
    @State private var busca = ""
    @State private var seleccion: UUID?
    @State private var monitor: Any?

    private let lado: CGFloat = 104

    /// La elegida, o la primera si aún no has elegido ninguna (al abrir la app
    /// la lista puede llegar después de que aparezca la pestaña).
    private func elegida(_ l: [(decision: Decision, item: MediaItem)]) -> UUID? {
        seleccion.flatMap { s in l.contains { $0.item.id == s } ? s : nil }
            ?? seleccion.flatMap { s in store.clasificadas.contains { $0.item.id == s } ? s : nil }
            ?? l.first?.item.id
    }

    private var lista: [(decision: Decision, item: MediaItem)] {
        store.clasificadas.filter { e in
            (filtro == nil || e.item.decision == filtro)
                && (busca.isEmpty || e.item.name.localizedCaseInsensitiveContains(busca))
        }
    }

    var body: some View {
        let l = lista
        Group {
            if store.doneCount == 0 {
                vacio
            } else {
                VStack(spacing: 0) {
                    barra(mostrando: l.count)
                    Divider()
                    HStack(spacing: 0) {
                        rejilla(l)
                        Divider()
                        detalle(l)
                            .frame(width: 360)
                    }
                }
            }
        }
        .onAppear { instalarTeclas() }
        .onDisappear { quitarTeclas() }
    }

    // MARK: Barra de filtros

    private func barra(mostrando n: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                chip("Todas", store.doneCount, .secondary, filtro == nil) { filtro = nil }
                ForEach(store.categories) { c in
                    chip(c.name, store.count(for: c.id), c.tint, filtro == c.id) { filtro = c.id }
                }
                Spacer()
                TextField("Buscar por nombre", text: $busca)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }
            HStack {
                Text("Lo último que clasificaste, primero. Elige una y pulsa otra tecla para cambiarla.")
                Spacer()
                if n != store.doneCount { Text("mostrando \(n)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func chip(_ texto: String, _ n: Int, _ tinte: Color, _ activo: Bool,
                      _ accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            HStack(spacing: 5) {
                Circle().fill(tinte).frame(width: 7, height: 7)
                Text(texto)
                Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(activo ? tinte.opacity(0.22) : Color.gray.opacity(0.1)))
            .overlay(Capsule().strokeBorder(activo ? tinte.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Rejilla

    private func rejilla(_ l: [(decision: Decision, item: MediaItem)]) -> some View {
        ScrollViewReader { sp in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: lado, maximum: lado + 30), spacing: 10)],
                          spacing: 12) {
                    let sel = elegida(l)
                    ForEach(l, id: \.item.id) { e in
                        celda(e.item, elegida: e.item.id == sel)
                            .id(e.item.id)
                            .onTapGesture { seleccion = e.item.id }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: seleccion) { _, s in
                if let s { withAnimation(.easeOut(duration: 0.15)) { sp.scrollTo(s) } }
            }
        }
    }

    private func celda(_ item: MediaItem, elegida: Bool) -> some View {
        let cat = item.decision.flatMap { store.category($0) }
        return VStack(spacing: 4) {
            Thumb(item: item, size: lado)
                .overlay(alignment: .topTrailing) {
                    if let cat {
                        Image(systemName: cat.symbol)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(cat.tint))
                            .padding(4)
                            .shadow(radius: 1.5)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(elegida ? Color.accentColor : .clear, lineWidth: 3))
            Text(item.name)
                .font(.caption2).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(elegida ? .primary : .secondary)
        }
        .frame(width: lado)
        .contentShape(Rectangle())
    }

    // MARK: Detalle

    @ViewBuilder
    private func detalle(_ l: [(decision: Decision, item: MediaItem)]) -> some View {
        let sel = elegida(l)
        if let e = l.first(where: { $0.item.id == sel })
            ?? store.clasificadas.first(where: { $0.item.id == sel }),
           let dec = e.item.decision, let actual = store.category(dec) {
            let item = e.item
            VStack(alignment: .leading, spacing: 12) {
                VistaPrevia(item: item)
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color.black.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.headline).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 8) {
                        if let d = item.date { Text(d.spanish) }
                        Text(item.fileSize.humanSize)
                        if item.kind == .video, item.duration > 0 { Text(formatDuration(item.duration)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text("Está en").foregroundStyle(.secondary)
                    Label(actual.name, systemImage: actual.symbol)
                        .fontWeight(.semibold).foregroundStyle(actual.tint)
                    if let a = e.decision.anteriores?.last, let antes = store.category(a) {
                        Text("· antes \(antes.name)").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if let f = e.decision.cambiada ?? e.decision.fecha {
                    Text((e.decision.cambiada != nil ? "Cambiada el " : "Clasificada el ") + f.spanish)
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cambiar a").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(store.categories) { c in
                        let esta = c.id == dec
                        Button { cambiar(item.id, a: c.id) } label: {
                            HStack(spacing: 8) {
                                Text("\(store.tecla(de: c))")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .frame(width: 18, height: 18)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(c.tint.opacity(0.25)))
                                Image(systemName: c.symbol)
                                Text(c.name).fontWeight(.medium)
                                Spacer()
                                if esta { Image(systemName: "checkmark") }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(c.tint.opacity(esta ? 0.25 : 0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(c.tint.opacity(esta ? 0.8 : 0.35)))
                            .foregroundStyle(c.tint)
                        }
                        .buttonStyle(.plain)
                        .disabled(esta)
                        .help(esta ? "Ya está aquí" : "Se copia en: " + c.folders.joined(separator: ", ")
                              + ", y se quita de " + actual.folders.joined(separator: ", "))
                    }
                }

                HStack {
                    Button {
                        devolver(item.id)
                    } label: { Label("Devolver a pendientes", systemImage: "arrow.uturn.backward") }
                        .help("Vuelve a Pendientes para clasificarla otra vez, y se quita de su carpeta")
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    } label: { Image(systemName: "folder") }
                        .help("Mostrar en el Finder")
                }

                Spacer(minLength: 0)

                Text("←/→ moverse · \(store.categories.count > 1 ? "1-\(store.categories.count)" : "1") cambiar · ⌘Z deshacer")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "hand.point.left").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Elige una foto para verla y cambiarla").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var vacio: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 46, weight: .light)).foregroundStyle(.tertiary)
            Text(store.isScanning ? "Recuperando tu historial…" : "Aún no has clasificado nada")
                .font(.title2.weight(.medium))
            Text("Aquí irán apareciendo las que clasifiques, la última arriba.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Acciones

    /// Cambia la seleccionada. Si con el filtro puesto deja de verse, la
    /// selección pasa a la que ocupa su sitio, para seguir revisando sin saltos.
    private func cambiar(_ id: UUID, a categoryID: Int) {
        let antes = lista.firstIndex { $0.item.id == id } ?? 0
        store.cambiarDecision(id, a: categoryID)
        mantenerSitio(id, antes)
    }

    private func devolver(_ id: UUID) {
        let antes = lista.firstIndex { $0.item.id == id } ?? 0
        store.devolverAPendientes(id)
        mantenerSitio(id, antes)
    }

    private func mantenerSitio(_ id: UUID, _ posicion: Int) {
        let l = lista
        if l.contains(where: { $0.item.id == id }) { return }
        seleccion = l.indices.contains(posicion) ? l[posicion].item.id : l.last?.item.id
    }

    // MARK: Teclado

    private func instalarTeclas() {
        quitarTeclas()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.modifierFlags.contains(.command) { return e }
            // escribiendo en el buscador, las teclas son para el buscador
            if NSApp.keyWindow?.firstResponder is NSTextView { return e }
            let l = lista
            guard !l.isEmpty else { return e }
            let sel = elegida(l)
            let i = l.firstIndex { $0.item.id == sel } ?? 0

            switch e.keyCode {
            case 123: seleccion = l[max(0, i - 1)].item.id; return nil
            case 124: seleccion = l[min(l.count - 1, i + 1)].item.id; return nil
            default: break
            }
            if let ch = e.charactersIgnoringModifiers, let n = Int(ch),
               let c = store.categoria(enTecla: n), let s = sel {
                cambiar(s, a: c.id)
                return nil
            }
            return e
        }
    }

    private func quitarTeclas() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// La foto o el vídeo en grande dentro del panel de detalle.
private struct VistaPrevia: View {
    let item: MediaItem
    @State private var imagen: NSImage?

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let imagen {
                    Image(nsImage: imagen).resizable().aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(item.rot)))
                } else {
                    ProgressView()
                }
            case .video:
                VideoPane(url: item.url, muted: true).id(item.id)
            }
        }
        .task(id: item.url) {
            imagen = nil
            if item.kind == .image {
                imagen = await DisplayImageLoader.shared.image(for: item.url, maxPixel: 1200)
            }
        }
    }
}
