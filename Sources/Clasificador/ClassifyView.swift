import AVKit
import AppKit
import ImageIO
import SwiftUI

// MARK: - Carga de la imagen grande

/// Carga la imagen a tamaño de pantalla (no a tamaño original) y guarda unas
/// pocas en memoria, incluida la siguiente, para que el paso sea instantáneo.
actor DisplayImageLoader {
    static let shared = DisplayImageLoader()
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []

    func image(for url: URL, maxPixel: CGFloat = 2400) -> NSImage? {
        let clave = "\(Int(maxPixel))|\(url.path)"
        if let c = cache[clave] { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[clave] = img
        order.append(clave)
        if order.count > 6 { cache.removeValue(forKey: order.removeFirst()) }
        return img
    }
}

// MARK: - Rueda del trackpad: deslizar para clasificar, o desplazar si hay zoom

struct SwipeCatcher: NSViewRepresentable {
    var enabled: Bool
    var onSwipe: (SwipeDirection) -> Void
    var onPan: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        SwipeView(enabled: enabled, onSwipe: onSwipe, onPan: onPan)
    }
    func updateNSView(_ v: NSView, context: Context) {
        guard let s = v as? SwipeView else { return }
        s.enabled = enabled
        s.onSwipe = onSwipe
        s.onPan = onPan
    }

    final class SwipeView: NSView {
        var enabled: Bool
        var onSwipe: (SwipeDirection) -> Void
        var onPan: (CGSize) -> Void
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0

        init(enabled: Bool, onSwipe: @escaping (SwipeDirection) -> Void,
             onPan: @escaping (CGSize) -> Void) {
            self.enabled = enabled
            self.onSwipe = onSwipe
            self.onPan = onPan
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func scrollWheel(with e: NSEvent) {
            guard enabled else {
                onPan(CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY))
                return
            }
            switch e.phase {
            case .began: dx = 0; dy = 0
            case .changed: dx += e.scrollingDeltaX; dy += e.scrollingDeltaY
            case .ended:
                let umbral: CGFloat = 55
                if abs(dx) > abs(dy), abs(dx) > umbral {
                    onSwipe(dx > 0 ? .right : .left)
                } else if abs(dy) > umbral {
                    onSwipe(dy > 0 ? .up : .down)
                }
                dx = 0; dy = 0
            default: break
            }
        }
    }
}

enum SwipeDirection { case left, right, up, down }

// MARK: - Vista de clasificación

struct ClassifyView: View {
    @EnvironmentObject var store: AppStore

    @State private var nsImage: NSImage?
    @State private var gemelaImage: NSImage?
    @State private var showInfo = false
    @State private var showFilmstrip = true
    @State private var comparando = false
    @State private var muted = true
    @State private var flash: Category?
    @State private var monitor: Any?
    @State private var dragOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    private var haciendoZoom: Bool { zoom > 1.01 }

    /// Deslizar mapea a la POSICIÓN de la clasificación en esta sesión, no a un
    /// id fijo: si la sesión solo tiene dos, arriba y abajo no hacen nada.
    private func category(for d: SwipeDirection) -> Int? {
        let posicion: Int
        switch d {
        case .left: posicion = 1
        case .right: posicion = 2
        case .up: posicion = 3
        case .down: posicion = 4
        }
        return store.categoria(enTecla: posicion)?.id
    }

    /// La foto de la que la actual es copia exacta, si la hay.
    private var gemela: MediaItem? {
        guard let n = store.current?.duplicateOfName else { return nil }
        return store.items.first { $0.name == n && $0.id != store.current?.id }
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                empty("El pool está vacío",
                      "Ve a la pestaña Pool y arrastra ahí tus fotos.", "tray")
            } else if !store.hasPending {
                empty("¡Terminado!",
                      "No queda nada por clasificar. Mira el resumen para ver el reparto.",
                      "checkmark.circle")
            } else {
                main
            }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private var main: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stage
            if showFilmstrip { filmstrip }
            Divider()
            infoBar
            footer
        }
        .task(id: store.current?.id) { await loadCurrent() }
    }

    private func loadCurrent() async {
        zoom = 1; pan = .zero; comparando = false; gemelaImage = nil
        guard let item = store.current else { nsImage = nil; return }
        nsImage = item.kind == .image
            ? await DisplayImageLoader.shared.image(for: item.url)
            : nil

        let next = store.currentIndex + 1
        if store.items.indices.contains(next) {
            let n = store.items[next]
            if n.kind == .image {
                Task.detached(priority: .utility) {
                    _ = await DisplayImageLoader.shared.image(for: n.url)
                }
            }
        }
    }

    // MARK: Cabecera

    private var header: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 4)

            HStack(spacing: 12) {
                Text("\(store.doneCount) de \(store.items.count)")
                    .font(.caption.monospacedDigit())
                Spacer()
                ForEach(store.categories) { c in
                    HStack(spacing: 4) {
                        Circle().fill(c.tint).frame(width: 7, height: 7)
                        Text("\(c.name) \(store.count(for: c.id))")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }

    private var progress: Double {
        store.items.isEmpty ? 0 : Double(store.doneCount) / Double(store.items.count)
    }

    // MARK: Escenario

    private var stage: some View {
        ZStack {
            Color.black.opacity(0.92)

            if let item = store.current {
                if comparando, let g = gemela {
                    comparacion(item, g)
                } else {
                    medioConZoom(item)
                }

                SwipeCatcher(enabled: !haciendoZoom && !comparando) { d in
                    if let c = category(for: d) { apply(c) }
                } onPan: { delta in
                    pan.width += delta.width
                    pan.height += delta.height
                }
                .allowsHitTesting(true)
                .opacity(0.001)

                VStack {
                    HStack(alignment: .top) {
                        barraHerramientas(item)
                        Spacer()
                        if showInfo { panelCompleto(item) }
                    }
                    Spacer()
                    if let d = item.decision, let c = store.category(d) { avisoYaClasificada(c) }
                    if item.isDuplicate && !comparando { avisoDuplicado(item) }
                }
                .padding(14)
            }

            if let f = flash {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(f.tint, lineWidth: 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(f.tint.opacity(0.14)))
                    .padding(8)
                    .overlay {
                        Label(f.name, systemImage: f.symbol)
                            .font(.system(size: 34, weight: .semibold))
                            .padding(.horizontal, 26).padding(.vertical, 14)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(f.tint)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Coloca la imagen respetando la rotación: si está de canto, el hueco que
    /// tiene que caber es el de la imagen girada, no el de la original.
    @ViewBuilder
    private func medioConZoom(_ item: MediaItem) -> some View {
        GeometryReader { geo in
            let libre = CGSize(width: geo.size.width - 28, height: geo.size.height - 28)
            let deCanto = item.rot % 180 != 0
            let w = CGFloat(max(item.width, 1)), h = CGFloat(max(item.height, 1))
            let aspecto = deCanto ? h / w : w / h
            let cajaW = min(libre.width, libre.height * aspecto)
            let cajaH = cajaW / aspecto
            let dibujo = deCanto ? CGSize(width: cajaH, height: cajaW)
                                 : CGSize(width: cajaW, height: cajaH)

            medio(item)
                .frame(width: dibujo.width, height: dibujo.height)
                .rotationEffect(.degrees(Double(item.rot)))
                .scaleEffect(zoom)
                .offset(x: pan.width + dragOffset.width, y: pan.height + dragOffset.height)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(MagnifyGesture()
                    .onChanged { g in zoom = max(1, min(8, g.magnification * zoom)) }
                    .onEnded { _ in if zoom <= 1.01 { zoom = 1; pan = .zero } })
                .gesture(
                    DragGesture()
                        .onChanged { g in
                            if haciendoZoom {
                                pan.width += g.translation.width - dragOffset.width
                                pan.height += g.translation.height - dragOffset.height
                                dragOffset = g.translation
                            } else {
                                dragOffset = g.translation
                            }
                        }
                        .onEnded { g in
                            let t = g.translation
                            withAnimation(.easeOut(duration: 0.15)) { dragOffset = .zero }
                            guard !haciendoZoom else { return }
                            let umbral: CGFloat = 90
                            if abs(t.width) > abs(t.height), abs(t.width) > umbral {
                                if let c = category(for: t.width < 0 ? .left : .right) { apply(c) }
                            } else if abs(t.height) > umbral {
                                if let c = category(for: t.height < 0 ? .up : .down) { apply(c) }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if haciendoZoom { zoom = 1; pan = .zero } else { zoom = 2.5 }
                    }
                }
        }
    }

    @ViewBuilder
    private func medio(_ item: MediaItem) -> some View {
        switch item.kind {
        case .image:
            if let nsImage {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit).id(item.id)
            } else {
                ProgressView().controlSize(.large)
            }
        case .video:
            VideoPane(url: item.url, muted: muted).id(item.id)
        }
    }

    /// Duplicado y original, uno al lado del otro.
    private func comparacion(_ a: MediaItem, _ b: MediaItem) -> some View {
        HStack(spacing: 10) {
            ladoComparacion("Esta", a, nsImage, Color.orange)
            ladoComparacion("Su gemela", b, gemelaImage, Color.secondary)
        }
        .padding(16)
        .task(id: b.id) {
            gemelaImage = await DisplayImageLoader.shared.image(for: b.url, maxPixel: 1600)
        }
    }

    private func ladoComparacion(_ titulo: String, _ item: MediaItem,
                                 _ img: NSImage?, _ tinte: Color) -> some View {
        VStack(spacing: 6) {
            Text(titulo).font(.caption.weight(.semibold)).foregroundStyle(tinte)
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
            VStack(spacing: 1) {
                Text(item.name).font(.caption2).lineLimit(1)
                Text("\(item.fileSize.humanSize) · \(item.width)×\(item.height)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).stroke(tinte.opacity(0.4)))
    }

    // MARK: Herramientas flotantes

    private func barraHerramientas(_ item: MediaItem) -> some View {
        HStack(spacing: 2) {
            boton("rotate.left", "Girar a la izquierda (⇧R)") { store.rotate(-90) }
            boton("rotate.right", "Girar a la derecha (R)") { store.rotate(90) }
            if item.rot != 0 {
                Text("\(item.rot)°")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
            separador
            boton("minus.magnifyingglass", "Alejar (−)") { ajustarZoom(-0.5) }
            boton("plus.magnifyingglass", "Acercar (+)") { ajustarZoom(0.5) }
            if haciendoZoom {
                Text(String(format: "%.0f%%", zoom * 100))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 3)
                boton("arrow.up.left.and.arrow.down.right", "Ajustar (0)") {
                    withAnimation { zoom = 1; pan = .zero }
                }
            }
            separador
            boton("arrow.up.left.and.arrow.down.right.magnifyingglass", "Pantalla completa (F)") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            boton(showFilmstrip ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2",
                  "Tira de miniaturas (T)") { showFilmstrip.toggle() }
            boton(showInfo ? "info.circle.fill" : "info.circle",
                  "Todos los datos (I)") { showInfo.toggle() }
            separador
            boton("eye", "Abrir en Vista previa (V)") { NSWorkspace.shared.open(item.url) }
            boton("folder", "Mostrar en el Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            if item.kind == .video {
                boton(muted ? "speaker.slash" : "speaker.wave.2", "Sonido (M)") { muted.toggle() }
            }
            if gemela != nil {
                separador
                boton("rectangle.on.rectangle", "Comparar con su gemela (C)") {
                    comparando.toggle()
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
    }

    private var separador: some View {
        Divider().frame(height: 15).padding(.horizontal, 3)
    }

    private func boton(_ icono: String, _ ayuda: String, _ accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Image(systemName: icono).frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .help(ayuda)
    }

    private func ajustarZoom(_ d: CGFloat) {
        withAnimation(.easeOut(duration: 0.12)) {
            zoom = max(1, min(8, zoom + d))
            if zoom == 1 { pan = .zero }
        }
    }

    // MARK: Avisos y paneles

    /// Al volver atrás (⇧←) sobre una ya clasificada: dónde está y cómo cambiarla.
    private func avisoYaClasificada(_ c: Category) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.symbol)
            Text("Ya está en \(c.name)").font(.caption.weight(.bold))
            Text("pulsa otra tecla para cambiarla").font(.caption2)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(c.tint, lineWidth: 1.2))
        .foregroundStyle(c.tint)
    }

    private func avisoDuplicado(_ item: MediaItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("DUPLICADO").font(.caption.weight(.bold))
            Text("idéntica a «\(item.duplicateOfName ?? "")»").font(.caption2)
            if gemela != nil {
                Button("Comparar") { comparando = true }
                    .buttonStyle(.link).font(.caption2)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.orange, lineWidth: 1.2))
        .foregroundStyle(.orange)
    }

    /// Panel con TODO lo que se sabe del archivo.
    private func panelCompleto(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            grupo("Archivo", [
                ("Nombre", item.name),
                ("Tipo", item.kind == .image ? "Imagen" : "Vídeo"),
                ("Tamaño", item.fileSize.humanSize),
                ("Dimensiones", item.width > 0 ? "\(item.width) × \(item.height)" : "—"),
                item.kind == .video && item.duration > 0
                    ? ("Duración", formatDuration(item.duration)) : nil,
                item.rot != 0 ? ("Girada", "\(item.rot)° (se aplica a la copia)") : nil,
            ].compactMap { $0 })

            grupo("Fecha", [
                ("Cuándo", item.date?.spanish ?? "sin fecha"),
                ("Origen del dato", item.dateSource.isEmpty ? "—" : item.dateSource),
            ])

            if !item.cameraLines.isEmpty {
                grupo("Cámara", item.cameraLines)
            }

            if item.hasLocation, let la = item.latitude, let lo = item.longitude {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ubicación").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(String(format: "%.5f, %.5f", la, lo))
                        .font(.caption.monospaced())
                    Button {
                        if let u = URL(string: "https://maps.apple.com/?ll=\(la),\(lo)&q=Foto") {
                            NSWorkspace.shared.open(u)
                        }
                    } label: { Label("Ver en Mapas", systemImage: "map") }
                        .buttonStyle(.link).font(.caption)
                }
            } else {
                Text("Sin ubicación en el archivo")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if item.isDuplicate {
                Text("Duplicado exacto de «\(item.duplicateOfName ?? "")»")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func grupo(_ titulo: String, _ filas: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titulo).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            ForEach(filas, id: \.0) { k, v in
                HStack(alignment: .top, spacing: 6) {
                    Text(k).font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(v).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Tira de miniaturas

    private var filmstrip: some View {
        ScrollViewReader { sp in
            ScrollView(.horizontal, showsIndicators: false) {
                // LazyHStack, no HStack: con 32.000 fotos, el normal creaba las
                // 32.000 miniaturas de golpe y cada una arrancaba su carga.
                LazyHStack(spacing: 5) {
                    ForEach(store.items.indices, id: \.self) { i in
                        let it = store.items[i]
                        let actual = i == store.currentIndex
                        Thumb(item: it, size: 46)
                            .overlay {
                                if let d = it.decision, let c = store.category(d) {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(c.tint.opacity(0.45))
                                        .overlay(Image(systemName: c.symbol)
                                            .font(.caption2).foregroundStyle(.white))
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(actual ? Color.accentColor : .clear, lineWidth: 2.5))
                            .id(i)
                            .onTapGesture { store.currentIndex = i }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
            .frame(height: 62)
            .background(Color.black.opacity(0.35))
            .onChange(of: store.currentIndex) { _, n in
                withAnimation { sp.scrollTo(n, anchor: .center) }
            }
            .onAppear { sp.scrollTo(store.currentIndex, anchor: .center) }
        }
    }

    // MARK: Barra fija de datos

    private var infoBar: some View {
        HStack(spacing: 10) {
            if let item = store.current {
                Image(systemName: item.kind == .video ? "film" : "photo")
                    .foregroundStyle(.secondary)
                Text(item.name).lineLimit(1).fontWeight(.medium)
                if let d = item.date {
                    etiqueta(d.spanish, "calendar")
                    Text(item.dateSource)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                } else {
                    etiqueta("sin fecha", "calendar.badge.exclamationmark")
                }
                if item.width > 0 { etiqueta("\(item.width)×\(item.height)", "aspectratio") }
                etiqueta(item.fileSize.humanSize, "internaldrive")
                if item.kind == .video, item.duration > 0 {
                    etiqueta(formatDuration(item.duration), "clock")
                }
                if let c = item.camera { etiqueta(c, "camera") }
                if item.hasLocation { etiqueta("con ubicación", "mappin.and.ellipse") }
                Spacer()
                Text("\(store.currentIndex + 1) / \(store.items.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func etiqueta(_ t: String, _ icono: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icono).font(.caption2)
            Text(t).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Pie

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(store.categories) { c in
                    let esta = store.current?.decision == c.id
                    Button { apply(c.id) } label: {
                        HStack(spacing: 7) {
                            Text("\(store.tecla(de: c))")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 4).fill(c.tint.opacity(0.25)))
                            Image(systemName: c.symbol)
                            Text(c.name).fontWeight(.medium)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(c.tint.opacity(esta ? 0.32 : 0.14)))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(c.tint.opacity(esta ? 0.95 : 0.45), lineWidth: esta ? 2 : 1))
                        .foregroundStyle(c.tint)
                    }
                    .buttonStyle(.plain)
                    .help(hint(for: c))
                }
            }

            HStack(spacing: 12) {
                hintLabel(store.categories.count > 1 ? "1-\(store.categories.count)" : "1",
                          "clasificar")
                hintLabel("deslizar", pistaDeslizar)
                hintLabel("R", "girar")
                hintLabel("+ −", "zoom")
                hintLabel("F", "pantalla completa")
                hintLabel("I", "datos")
                hintLabel("⌘Z", "deshacer")
                hintLabel("⇧←", "volver y cambiar")
                Spacer()
                hintLabel("⇧←/→", "moverse sin clasificar")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.bottom, 11)
    }

    /// Se arma con las clasificaciones que tenga esta sesión, no con una lista fija.
    private var pistaDeslizar: String {
        let flechas = ["←", "→", "↑", "↓"]
        return store.categories.enumerated()
            .compactMap { i, c in i < flechas.count ? "\(flechas[i]) \(c.name)" : nil }
            .joined(separator: " · ")
    }

    private func hint(for c: Category) -> String {
        c.folders.isEmpty
            ? "Solo lo marca, no copia el archivo a ningún sitio."
            : "Copia en: " + c.folders.joined(separator: ", ")
    }

    private func hintLabel(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            Text(text)
        }
    }

    private func empty(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title2.weight(.medium))
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Acciones

    private func apply(_ categoryID: Int) {
        guard let c = store.category(categoryID), store.current != nil else { return }
        withAnimation(.easeOut(duration: 0.12)) { flash = c }
        store.classify(categoryID)
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.easeIn(duration: 0.15)) { flash = nil }
        }
    }

    // MARK: Teclado

    private func installKeyMonitor() {
        removeKeyMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.modifierFlags.contains(.command) { return e }
            guard let chars = e.charactersIgnoringModifiers else { return e }
            let shift = e.modifierFlags.contains(.shift)

            switch chars.lowercased() {
            case "1", "2", "3", "4":
                if let n = Int(chars), let c = store.categoria(enTecla: n) { apply(c.id); return nil }
            case "i": showInfo.toggle(); return nil
            case "m": muted.toggle(); return nil
            case "r": store.rotate(shift ? -90 : 90); return nil
            case "f": NSApp.keyWindow?.toggleFullScreen(nil); return nil
            case "t": showFilmstrip.toggle(); return nil
            case "v": if let u = store.current?.url { NSWorkspace.shared.open(u) }; return nil
            case "c": if gemela != nil { comparando.toggle() }; return nil
            case "+", "=": ajustarZoom(0.5); return nil
            case "-": ajustarZoom(-0.5); return nil
            case "0": withAnimation { zoom = 1; pan = .zero }; return nil
            default: break
            }

            switch e.keyCode {
            case 123:
                if shift { store.step(-1) } else if let c = category(for: .left) { apply(c) }
                return nil
            case 124:
                if shift { store.step(1) } else if let c = category(for: .right) { apply(c) }
                return nil
            case 126: if let c = category(for: .up) { apply(c) }; return nil
            case 125: if let c = category(for: .down) { apply(c) }; return nil
            default: return e
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

// MARK: - Reproductor de vídeo en bucle

/// `AVPlayerView` de AppKit a pelo, no el `VideoPlayer` de SwiftUI: aquel vive
/// en `_AVKit_SwiftUI` y fue el que tumbó la app el 9-oct (no encontraba la
/// clase `AVPlayerView`). Así hay una pieza menos que pueda fallar, y el bucle
/// lo lleva `AVPlayerLooper`, sin observadores que se quedaban colgados
/// (antes cada vídeo visto dejaba su reproductor vivo en memoria).
struct VideoPane: NSViewRepresentable {
    let url: URL
    let muted: Bool

    func makeCoordinator() -> Coordinador { Coordinador() }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        context.coordinator.cargar(url, muted: muted, en: v)
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.cargar(url, muted: muted, en: v)
        }
        v.player?.isMuted = muted
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: Coordinador) {
        coordinator.parar(v)
    }

    final class Coordinador {
        var url: URL?
        private var looper: AVPlayerLooper?

        func cargar(_ url: URL, muted: Bool, en v: AVPlayerView) {
            parar(v)
            let jugador = AVQueuePlayer()
            looper = AVPlayerLooper(player: jugador, templateItem: AVPlayerItem(url: url))
            jugador.isMuted = muted
            v.player = jugador
            jugador.play()
            self.url = url
        }

        func parar(_ v: AVPlayerView) {
            v.player?.pause()
            looper?.disableLooping()
            looper = nil
            v.player = nil
            url = nil
        }
    }
}
