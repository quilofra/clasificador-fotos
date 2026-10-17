import SwiftUI
import UniformTypeIdentifiers

struct PoolView: View {
    @EnvironmentObject var store: AppStore
    @Binding var tab: Tab

    @State private var selection = Set<UUID>()
    @State private var dropTargeted = false
    @State private var filter: String = ""
    @State private var onlyPending = false
    @State private var onlyDuplicates = false
    @State private var tipo: FiltroTipo = .todo
    @State private var anio: String = "todos"
    @State private var orden: AppStore.SortKey = .fecha
    @State private var ascendente = true

    enum FiltroTipo: String, CaseIterable, Identifiable {
        case todo, fotos, videos
        var id: String { rawValue }
        var label: String {
            switch self {
            case .todo: return "Todo"
            case .fotos: return "Solo fotos"
            case .videos: return "Solo vídeos"
            }
        }
    }

    private var anios: [String] {
        let f = DateFormatter(); f.dateFormat = "yyyy"
        let s = Set(store.items.compactMap { $0.date.map { f.string(from: $0) } })
        return ["todos"] + s.sorted()
    }

    private var visible: [MediaItem] {
        let f = DateFormatter(); f.dateFormat = "yyyy"
        return store.items.filter { it in
            if onlyPending && it.decision != nil { return false }
            if onlyDuplicates && !it.isDuplicate { return false }
            if tipo == .fotos && it.kind != .image { return false }
            if tipo == .videos && it.kind != .video { return false }
            if anio != "todos" {
                guard let d = it.date, f.string(from: d) == anio else { return false }
            }
            if !filter.isEmpty && !it.name.localizedCaseInsensitiveContains(filter) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                dropZone
            } else {
                toolbar
                Divider()
                list
                Divider()
                statusBar
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if dropTargeted && !store.items.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Zona de arrastre (pool vacío)

    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.55))
            VStack(spacing: 6) {
                Text("Vierte aquí tus fotos y vídeos")
                    .font(.title2.weight(.medium))
                Text("Arrastra archivos o carpetas enteras, de todos los sitios que quieras.\nSe irán acumulando en el pool.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Elegir archivos o carpetas…") { store.addToPool(pickFiles()) }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.06) : .clear)
    }

    // MARK: - Barra de herramientas

    private var toolbar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Button {
                    store.addToPool(pickFiles())
                } label: { Label("Añadir", systemImage: "plus") }

                TextField("Filtrar por nombre", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)

                Picker("", selection: $tipo) {
                    ForEach(FiltroTipo.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 110)

                Picker("", selection: $anio) {
                    ForEach(anios, id: \.self) {
                        Text($0 == "todos" ? "Todos los años" : $0).tag($0)
                    }
                }
                .labelsHidden().frame(width: 130)

                Toggle("Sin clasificar", isOn: $onlyPending).toggleStyle(.checkbox)
                Toggle("Duplicados", isOn: $onlyDuplicates).toggleStyle(.checkbox)

                Spacer()

                Menu {
                    ForEach(AppStore.SortKey.allCases) { k in
                        Button {
                            orden = k
                            store.sortPool(by: k, ascending: ascendente)
                        } label: {
                            if orden == k { Label(k.label, systemImage: "checkmark") }
                            else { Text(k.label) }
                        }
                    }
                    Divider()
                    Button(ascendente ? "Cambiar a descendente" : "Cambiar a ascendente") {
                        ascendente.toggle()
                        store.sortPool(by: orden, ascending: ascendente)
                    }
                } label: {
                    Label("Ordenar: \(orden.label)", systemImage: ascendente
                          ? "arrow.up" : "arrow.down")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Reordena el pool de verdad, así que también cambia el orden en que las verás")
            }

            HStack(spacing: 10) {
                if !selection.isEmpty {
                    Text("\(selection.count) seleccionadas")
                        .font(.caption).foregroundStyle(.secondary)

                    Menu {
                        ForEach(store.categories) { c in
                            Button {
                                store.classifyBatch(selection, to: c.id)
                                selection = []
                            } label: {
                                Label("\(c.name)  (\(c.folders.isEmpty ? "no copia" : c.folders.joined(separator: ", ")))",
                                      systemImage: c.symbol)
                            }
                        }
                    } label: {
                        Label("Clasificar las \(selection.count)", systemImage: "bolt.fill")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Las manda todas de golpe a una categoría, sin verlas una a una")

                    Button(role: .destructive) {
                        store.removeFromPool(selection)
                        selection = []
                    } label: { Label("Quitar del pool", systemImage: "minus.circle") }
                    .help("Los quita de la lista. No borra nada del disco.")

                    Button("Deseleccionar") { selection = [] }
                }

                Spacer()

                Button("Vaciar pool") { store.clearPool(); selection = [] }
                    .help("Vacía la lista. Tus archivos en disco no se tocan.")

                Button {
                    store.jumpToFirstPending()
                    tab = .classify
                } label: {
                    Label("Empezar a clasificar", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.hasPending)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Lista

    private var list: some View {
        List(visible, selection: $selection) { item in
            HStack(spacing: 11) {
                Thumb(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1)
                    HStack(spacing: 8) {
                        if let d = item.date {
                            Text(d.spanish)
                        }
                        Text(item.fileSize.humanSize)
                        if item.kind == .video, item.duration > 0 {
                            Text(formatDuration(item.duration))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if item.isDuplicate {
                    Text("duplicado")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.22)))
                        .foregroundStyle(.orange)
                        .help("Contenido idéntico a «\(item.duplicateOfName ?? "")»")
                }
                if let d = item.decision, let c = store.category(d) {
                    Text(c.name)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(c.tint.opacity(0.22)))
                        .foregroundStyle(c.tint)
                }
            }
            .padding(.vertical, 2)
            .tag(item.id)
        }
        .listStyle(.inset)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(store.items.count) archivos")
            Text("\(store.pendingCount) sin clasificar").foregroundStyle(.secondary)
            if store.duplicateCount > 0 {
                Text("\(store.duplicateCount) duplicados").foregroundStyle(.orange)
            }
            Spacer()
            if visible.count != store.items.count {
                Text("mostrando \(visible.count)").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                    as? Data, let u = URL(dataRepresentation: url, relativeTo: nil) {
                    urls.append(u)
                }
            }
            if !urls.isEmpty { store.addToPool(urls) }
        }
    }
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}
