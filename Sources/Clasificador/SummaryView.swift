import AppKit
import SwiftUI

struct SummaryView: View {
    @EnvironmentObject var store: AppStore
    @State private var showDiscarded = false
    @State private var aviso: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sessionsSection
                destinationSection
                categoriesSection
                statsSection
                if discarded.count > 0 { discardedSection }
                dangerSection
            }
            .padding(20)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var discarded: [MediaItem] { store.items.filter { $0.decision == 4 } }

    // MARK: Sesiones

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Sesiones").font(.headline)
                Spacer()
                Button {
                    store.showNewSessionDialog = true
                } label: { Label("Nueva", systemImage: "plus") }
                    .buttonStyle(.link)
            }
            Text("Cada sesión es un pool independiente, con sus propias fotos, sus decisiones y su carpeta destino. Sirve para tener varios trabajos a medias a la vez sin que se mezclen.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(store.sessionsByRecent) { s in
                    let activa = s.id == store.activeSessionID
                    HStack(spacing: 10) {
                        Image(systemName: activa ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(activa ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).fontWeight(activa ? .semibold : .regular)
                            Text(detalle(s)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.itemCount > 0 {
                            ProgressView(value: Double(s.doneCount),
                                         total: Double(max(1, s.itemCount)))
                                .frame(width: 70)
                        }
                        if !activa {
                            Button("Abrir") { store.openSession(s.id) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(activa ? Color.accentColor.opacity(0.08) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if !activa { store.openSession(s.id) } }
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
        }
    }

    private func detalle(_ s: SessionMeta) -> String {
        let estado = s.itemCount == 0 ? "vacía"
            : s.pendingCount == 0 ? "\(s.itemCount) archivos · terminada"
            : "\(s.doneCount) de \(s.itemCount) clasificadas"
        return "\(estado) · usada \(s.updatedAt.spanish)"
    }

    // MARK: Destino

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Carpeta destino").font(.headline)
            HStack(spacing: 9) {
                Text(store.destinationRoot.path)
                    .font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.head)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
                Button("Cambiar…") { chooseDestination() }
                Button {
                    store.revealDestination()
                } label: { Image(systemName: "folder") }
                    .help("Abrir en el Finder")
            }
            Text("Las fotos se **copian** aquí dentro, en una carpeta por sesión. Tus archivos originales no se mueven ni se modifican nunca.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 9) {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pendientes: \(store.pendingCount)").font(.callout)
                    Text("Lo que aún no has clasificado también vive aquí, en «Pendientes/». Al clasificar una, sale de ahí y se va a su carpeta.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Sincronizar") { store.sincronizarPendientes() }
                    .disabled(store.isScanning)
                    .help("Vuelve a dejar «Pendientes» con exactamente lo que falta")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
        }
    }

    private func chooseDestination() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = "Elige dónde guardar las fotos clasificadas"
        if p.runModal() == .OK, let u = p.url {
            store.destinationRoot = u
            store.save()
        }
    }

    // MARK: Clasificaciones de la sesión

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Clasificaciones de «\(store.sessionName)»").font(.headline)
            Text("Cada sesión tiene las suyas. La tecla es la posición: la primera es 1, la segunda 2… Los archivos ya clasificados no se tocan.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Category.catalogo) { c in
                    let puesta = store.categories.contains { $0.id == c.id }
                    let usadas = store.count(for: c.id)
                    Toggle(isOn: Binding(
                        get: { puesta },
                        set: { on in cambiar(c, activar: on) }
                    )) {
                        HStack(spacing: 8) {
                            Text(puesta ? "\(store.tecla(de: c))" : "–")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .frame(width: 17, height: 17)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(puesta ? c.tint.opacity(0.25) : Color.gray.opacity(0.12)))
                            Image(systemName: c.symbol).foregroundStyle(c.tint).frame(width: 16)
                            Text(c.name)
                            Text(c.folders.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if usadas > 0 {
                                Text("\(usadas) ya clasificadas")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(c.tint.opacity(0.18)))
                                    .foregroundStyle(c.tint)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(usadas > 0 && puesta)
                    .help(usadas > 0 && puesta
                          ? "No se puede quitar: ya has clasificado \(usadas) con ella"
                          : "")
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.4)))

            if let aviso { Text(aviso).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func cambiar(_ c: Category, activar: Bool) {
        var nuevas = store.categories
        if activar {
            guard !nuevas.contains(where: { $0.id == c.id }) else { return }
            nuevas.append(c)
        } else {
            guard nuevas.count > 1 else {
                aviso = "Una sesión necesita al menos una clasificación."
                return
            }
            nuevas.removeAll { $0.id == c.id }
        }
        let conservadas = store.setCategories(nuevas)
        aviso = conservadas.isEmpty ? nil
            : "Se han mantenido porque ya las has usado: " + conservadas.joined(separator: ", ")
    }

    // MARK: Reparto

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Reparto").font(.headline)
            ForEach(store.categories) { c in
                HStack(spacing: 11) {
                    Image(systemName: c.symbol)
                        .frame(width: 22)
                        .foregroundStyle(c.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).fontWeight(.medium)
                        Text(c.folders.isEmpty
                             ? "solo se marca, no se copia"
                             : "copia en " + c.folders.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(store.count(for: c.id))")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(c.tint)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(c.tint.opacity(0.09)))
            }

            HStack {
                Text("\(store.pendingCount) sin clasificar")
                Spacer()
                Text("\(store.items.count) en el pool")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    // MARK: Descartadas

    private var discardedSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Descartadas").font(.headline)
                Spacer()
                Button(showDiscarded ? "Ocultar" : "Ver las \(discarded.count)") {
                    showDiscarded.toggle()
                }
                .buttonStyle(.link)
            }
            Text("Se copian a la carpeta **Descartadas**, para poder repescarlas ahí mismo sin ir a buscar el original. Tus originales siguen intactos.")
                .font(.caption).foregroundStyle(.secondary)

            if showDiscarded {
                VStack(spacing: 0) {
                    ForEach(discarded.prefix(200)) { item in
                        HStack(spacing: 10) {
                            Thumb(item: item, size: 34)
                            Text(item.name).font(.caption).lineLimit(1)
                            Spacer()
                            Button("Repescar") { store.devolverAPendientes(item.id) }
                                .help("Vuelve a Pendientes y se quita de Descartadas")
                            .buttonStyle(.link).font(.caption)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            } label: { Image(systemName: "folder") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        Divider()
                    }
                    if discarded.count > 200 {
                        Text("y \(discarded.count - 200) más…")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.4)))
            }
        }
    }

    // MARK: Reinicio

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Esta sesión — «\(store.sessionName)»").font(.headline)
            Text("Se guarda sola: puedes cerrar la app a mitad, o irte a otra sesión, y al volver sigues donde lo dejaste.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reiniciar decisiones") {
                    for i in store.items.indices { store.items[i].decision = nil }
                    store.history = []
                    store.currentIndex = 0
                    store.save()
                }
                .help("Vuelve a dejar todo sin clasificar. No borra las copias ya hechas.")

                Button("Vaciar pool") { store.clearPool() }
                    .help("Vacía la lista. No borra nada del disco.")
            }
        }
    }
}
