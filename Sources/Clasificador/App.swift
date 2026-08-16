import AppKit
import SwiftUI

@main
struct ClasificadorApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    store.load()
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    // El guardado es diferido; al cerrar hay que forzarlo o se
                    // perderían las últimas decisiones.
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil, queue: .main
                    ) { _ in MainActor.assumeIsolated { store.saveNow() } }
                }
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Deshacer clasificación") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
            }
            CommandGroup(replacing: .newItem) {
                Button("Nueva sesión…") { store.showNewSessionDialog = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Añadir archivos al pool…") { store.addToPool(pickFiles()) }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

/// Panel de selección de archivos y carpetas.
@MainActor
func pickFiles() -> [URL] {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = true
    p.canChooseFiles = true
    p.message = "Elige fotos, vídeos o carpetas enteras para el pool"
    p.prompt = "Añadir"
    return p.runModal() == .OK ? p.urls : []
}

// MARK: - Ventana principal

enum Tab: Hashable { case pool, classify, summary }

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab: Tab = .pool

    var body: some View {
        VStack(spacing: 0) {
            TabBar(tab: $tab)
            Divider()
            Group {
                switch tab {
                case .pool: PoolView(tab: $tab)
                case .classify: ClassifyView()
                case .summary: SummaryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Vaya", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("Entendido", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

// MARK: - Selector de sesión

struct SessionMenu: View {
    @EnvironmentObject var store: AppStore

    @State private var nuevoNombre = ""
    @State private var renombrando = false
    @State private var nombreEditado = ""
    @State private var borrando: SessionMeta?

    var body: some View {
        Menu {
            Section("Cambiar de sesión") {
                ForEach(store.sessionsByRecent) { s in
                    Button {
                        store.openSession(s.id)
                    } label: {
                        if s.id == store.activeSessionID {
                            Label("\(s.name)  —  \(resumen(s))", systemImage: "checkmark")
                        } else {
                            Text("\(s.name)  —  \(resumen(s))")
                        }
                    }
                }
            }
            Divider()
            Button("Nueva sesión…") { store.showNewSessionDialog = true }
            Button("Renombrar «\(store.sessionName)»…") {
                nombreEditado = store.sessionName
                renombrando = true
            }
            Button("Duplicar «\(store.sessionName)»") {
                store.duplicateSession(store.activeSessionID)
            }
            Divider()
            Button("Eliminar «\(store.sessionName)»…", role: .destructive) {
                borrando = store.activeSession
            }
        } label: {
            // Con .borderlessButton macOS simplifica la etiqueta y descarta las
            // vistas extra, así que aquí solo caben el icono y el nombre.
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                Text(store.sessionName).fontWeight(.medium).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Cada sesión tiene su propio pool, sus decisiones y su carpeta destino")

        // Nueva sesión
        .sheet(isPresented: $store.showNewSessionDialog) { NuevaSesionSheet() }

        // Renombrar
        .alert("Renombrar sesión", isPresented: $renombrando) {
            TextField("Nombre", text: $nombreEditado)
            Button("Guardar") { store.renameSession(store.activeSessionID, to: nombreEditado) }
            Button("Cancelar", role: .cancel) {}
        }

        // Eliminar
        .alert("¿Eliminar «\(borrando?.name ?? "")»?",
               isPresented: Binding(get: { borrando != nil },
                                    set: { if !$0 { borrando = nil } })) {
            Button("Eliminar", role: .destructive) {
                if let b = borrando { store.deleteSession(b.id) }
                borrando = nil
            }
            Button("Cancelar", role: .cancel) { borrando = nil }
        } message: {
            Text("Se borra solo la sesión: qué fotos había en el pool y cómo las clasificaste. Ni tus fotos originales ni las copias ya hechas se tocan.")
        }
    }

    private func resumen(_ s: SessionMeta) -> String {
        s.itemCount == 0 ? "vacía"
            : s.pendingCount == 0 ? "\(s.itemCount), terminada"
            : "\(s.pendingCount) sin clasificar de \(s.itemCount)"
    }
}

// MARK: - Crear sesión eligiendo sus clasificaciones

struct NuevaSesionSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var nombre = ""
    @State private var elegidas: Set<Int> = Set(Category.catalogo.map(\.id))

    private var seleccion: [Category] {
        Category.catalogo.filter { elegidas.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nueva sesión").font(.title3.weight(.semibold))
            Text("Un pool nuevo, vacío e independiente. La sesión actual se guarda tal cual está y puedes volver a ella cuando quieras.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Nombre de la sesión", text: $nombre)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 7) {
                Text("Clasificaciones de esta sesión").font(.callout.weight(.medium))
                Text("Solo saldrán estas al clasificar, y en este orden. La tecla es la posición: la primera es 1, la segunda 2…")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(Category.catalogo.enumerated()), id: \.element.id) { _, c in
                    let puesta = elegidas.contains(c.id)
                    let pos = seleccion.firstIndex { $0.id == c.id }.map { $0 + 1 }
                    Toggle(isOn: Binding(
                        get: { puesta },
                        set: { on in
                            if on { elegidas.insert(c.id) }
                            else if elegidas.count > 1 { elegidas.remove(c.id) }
                        }
                    )) {
                        HStack(spacing: 8) {
                            Text(pos.map { "\($0)" } ?? "–")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .frame(width: 17, height: 17)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(puesta ? c.tint.opacity(0.25) : Color.gray.opacity(0.12)))
                            Image(systemName: c.symbol).foregroundStyle(c.tint).frame(width: 16)
                            Text(c.name)
                            Text(c.folders.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.4)))

            HStack {
                Text("Carpeta destino: \(store.destinationRoot.lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { cerrar() }
                Button("Crear") {
                    store.newSession(named: nombre, categorias: seleccion)
                    cerrar()
                }
                .buttonStyle(.borderedProminent)
                .disabled(seleccion.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private func cerrar() {
        nombre = ""
        elegidas = Set(Category.catalogo.map(\.id))
        store.showNewSessionDialog = false
        dismiss()
    }
}

struct TabBar: View {
    @Binding var tab: Tab
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 4) {
            SessionMenu()
            Divider().frame(height: 18).padding(.horizontal, 6)
            item(.pool, "Pool", "tray.full", badge: store.items.count)
            item(.classify, "Clasificar", "rectangle.stack", badge: store.pendingCount)
            item(.summary, "Resumen", "chart.bar", badge: nil)
            Spacer()
            if store.canUndo {
                Button {
                    store.undo()
                } label: {
                    Label("Deshacer", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Deshacer la última clasificación (⌘Z)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func item(_ t: Tab, _ label: String, _ icon: String, badge: Int?) -> some View {
        Button {
            tab = t
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
                if let b = badge, b > 0 {
                    Text("\(b)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tab == t ? Color.accentColor.opacity(0.18) : .clear)
            )
            .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
