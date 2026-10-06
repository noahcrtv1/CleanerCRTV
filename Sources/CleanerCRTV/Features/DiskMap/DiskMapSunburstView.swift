import CleanerCore
import SwiftUI

/// Cores do mapa: uma por ramo do primeiro anel, clareando para fora. Cinzas para o que não é pasta de verdade.
enum DiskMapPalette {
    static let hues: [Color] = [
        Brand.violet, Brand.teal, Brand.orange, Brand.magenta, Brand.green,
        Color(red: 0.25, green: 0.50, blue: 0.97), Brand.red, Color(red: 0.95, green: 0.76, blue: 0.16),
    ]
    private static let shades: [[Color]] = hues.map { base in
        (0..<8).map { step in step == 0 ? base : base.mix(with: .white, by: min(0.62, Double(step) * 0.11)) }
    }
    static let smallFiles = Color(white: 0.62)
    static let merged = Color(white: 0.52).opacity(0.75)
    static let system = Color(white: 0.4)
    static let restricted = Color(white: 0.46)

    static func color(branch: Int, depth: Int) -> Color {
        guard branch >= 0 else { return merged }
        return shades[branch % shades.count][min(max(depth - 1, 0), 7)]
    }

    static func color(for arc: DiskMapArc) -> Color {
        switch arc.kind {
        case .aggregate: smallFiles
        case .merged: merged
        case .synthetic: system
        case .directory, .file: color(branch: arc.branch, depth: arc.depth)
        }
    }
}

/// Medidas do gráfico para um tamanho de tela: centro, furo e largura dos anéis.
struct DiskMapSunburstGeometry {
    let center: CGPoint
    let radius: CGFloat
    let hole: CGFloat
    let ring: CGFloat

    init(size: CGSize, rings: Int) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        radius = max(24, min(size.width, size.height) / 2 - 6)
        hole = radius * 0.28
        ring = (radius - hole) / CGFloat(max(1, rings))
    }

    /// Anel (0 = centro) e ângulo (0 = topo, sentido horário) do ponto; nil fora do gráfico.
    func locate(_ point: CGPoint) -> (depth: Int, angle: Double)? {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        let distance = CGFloat((dx * dx + dy * dy).squareRoot())
        guard distance <= radius else { return nil }
        guard distance >= hole else { return (0, 0) }
        var angle = atan2(dx, -dy) * 180 / .pi
        if angle < 0 { angle += 360 }
        return (Int((distance - hole) / ring) + 1, angle)
    }

    func sector(from start: Double, to end: Double, inner: CGFloat, outer: CGFloat) -> Path {
        var path = Path()
        if end - start >= 359.99 {
            path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            return path
        }
        path.addArc(center: center, radius: outer, startAngle: .degrees(start - 90), endAngle: .degrees(end - 90), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .degrees(end - 90), endAngle: .degrees(start - 90), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Desenha os anéis. Recebe tudo por valor: o Canvas pode pedir um quadro a qualquer momento.
struct DiskMapSunburstRenderer {
    let layout: DiskMapSunburstLayout
    let zoom: DiskMapZoom?
    let highlight: Int?
    let selected: [Int]
    let collected: Set<ObjectIdentifier>

    /// Um conjunto de setores e como ele aparece agora: janela angular visível e anel deslocado.
    private struct Pass {
        let layout: DiskMapSunburstLayout
        var base = 0.0
        var factor = 1.0
        var ringShift = 0.0
        var visibleStart = 0.0
        var scale = 1.0
        var offset = 0.0
        var alpha = 1.0
    }

    private struct Sector {
        let path: Path
        let outline: Path
        let cut: Bool
    }

    func draw(_ context: inout GraphicsContext, size: CGSize, now: Date) {
        let geometry = DiskMapSunburstGeometry(size: size, rings: layout.maxDepth)
        let passes: [Pass]
        var animating = false
        let progress = zoom?.progress(at: now) ?? 1
        if let zoom, progress < 1 {
            animating = true
            // t = 0 mostra a pasta de fora; t = 1, a de dentro.
            let t = zoom.zoomingIn ? progress : 1 - progress
            let outer = zoom.zoomingIn ? zoom.other : layout
            let inner = zoom.zoomingIn ? layout : zoom.other
            let start = zoom.start * t
            let end = 360 + (zoom.end - 360) * t
            let scale = 360 / max(end - start, 1e-9)
            let offset = Double(zoom.depth) * t
            passes = [
                Pass(layout: outer, visibleStart: start, scale: scale, offset: offset),
                Pass(layout: inner, base: zoom.start, factor: (zoom.end - zoom.start) / 360,
                     ringShift: Double(zoom.depth), visibleStart: start, scale: scale, offset: offset, alpha: t),
            ]
        } else {
            passes = [Pass(layout: layout)]
        }

        let hovered = animating ? nil : highlight.flatMap { $0 < layout.arcs.count ? layout.arcs[$0] : nil }
        context.drawLayer { layer in
            var cuts = Path()
            for pass in passes {
                for (index, arc) in pass.layout.arcs.enumerated() {
                    guard let sector = sector(for: arc, in: pass, geometry) else { continue }
                    let restricted = arc.node?.isRestricted == true
                    var color = restricted ? DiskMapPalette.restricted : DiskMapPalette.color(for: arc)
                    var alpha = pass.alpha
                    if !animating {
                        if let hovered, index == highlight || arc.isInside(hovered) { color = color.mix(with: .white, by: 0.25) }
                        if !collected.isEmpty, isCollected(arc) { alpha *= 0.25 }
                    }
                    layer.fill(sector.path, with: .color(color.opacity(alpha)), style: FillStyle(eoFill: true))
                    if arc.kind == .synthetic || restricted { hatch(&layer, sector.path, alpha: alpha) }
                    if sector.cut { cuts.addPath(sector.outline) }
                }
            }
            // Vãos entre setores: recortados (transparentes), servem em qualquer fundo.
            layer.blendMode = .destinationOut
            layer.stroke(cuts, with: .color(.black), lineWidth: 1)
        }
        guard !animating else { return }
        let base = Pass(layout: layout)
        for index in selected where index < layout.arcs.count {
            if let sector = sector(for: layout.arcs[index], in: base, geometry) {
                context.stroke(sector.outline, with: .color(.accentColor), lineWidth: 2)
            }
        }
        if let highlight, highlight < layout.arcs.count, let sector = sector(for: layout.arcs[highlight], in: base, geometry) {
            context.stroke(sector.outline, with: .color(.white.opacity(0.95)), lineWidth: 2)
        }
    }

    private func sector(for arc: DiskMapArc, in pass: Pass, _ geometry: DiskMapSunburstGeometry) -> Sector? {
        var start = (pass.base + arc.start * pass.factor - pass.visibleStart) * pass.scale
        var end = (pass.base + arc.end * pass.factor - pass.visibleStart) * pass.scale
        guard end > 0, start < 360 else { return nil }
        start = max(0, start)
        end = min(360, end)
        guard end - start > 0.02 else { return nil }
        let position = Double(arc.depth) + pass.ringShift - pass.offset
        var inner = geometry.hole + CGFloat(position - 1) * geometry.ring
        var outer = inner + geometry.ring
        guard outer > geometry.hole + 0.5, inner < geometry.radius - 0.5 else { return nil }
        inner = max(geometry.hole, inner)
        outer = min(geometry.radius, outer)
        let path = geometry.sector(from: start, to: end, inner: inner, outer: outer)
        let full = end - start >= 359.99
        var outline = path
        if full {
            outline = Path()
            outline.addEllipse(in: CGRect(x: geometry.center.x - outer, y: geometry.center.y - outer, width: outer * 2, height: outer * 2))
            outline.addEllipse(in: CGRect(x: geometry.center.x - inner, y: geometry.center.y - inner, width: inner * 2, height: inner * 2))
        }
        // Setor fino demais perderia a cor inteira para o vão.
        let cut = full || (end - start) * .pi / 180 * Double(outer) > 2.5
        return Sector(path: path, outline: outline, cut: cut)
    }

    private func isCollected(_ arc: DiskMapArc) -> Bool {
        var current: DiskMapNode? = arc.node ?? arc.parent
        while let node = current {
            if collected.contains(ObjectIdentifier(node)) { return true }
            current = node.parent
        }
        return false
    }

    /// Listras diagonais: área somente leitura.
    private func hatch(_ layer: inout GraphicsContext, _ path: Path, alpha: Double) {
        var clipped = layer
        clipped.clip(to: path, style: FillStyle(eoFill: true))
        let box = path.boundingRect
        var lines = Path()
        var x = box.minX - box.height
        while x < box.maxX {
            lines.move(to: CGPoint(x: x, y: box.maxY))
            lines.addLine(to: CGPoint(x: x + box.height, y: box.minY))
            x += 7
        }
        clipped.stroke(lines, with: .color(.white.opacity(0.22 * alpha)), lineWidth: 1.5)
    }
}

/// Gráfico interativo de raios de sol da pasta em foco.
struct DiskMapSunburstView: View {
    let map: DiskMapModel

    @Environment(\.appModel) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverArc: Int?
    @State private var hoverCenter = false

    var body: some View {
        if let layout = map.layout, let focus = map.focus {
            GeometryReader { proxy in
                let geometry = DiskMapSunburstGeometry(size: proxy.size, rings: layout.maxDepth)
                let zoom = reduceMotion ? nil : map.zoom
                let highlight = hoverArc ?? map.hovered.flatMap { layout.arcIndex(of: $0) }
                let renderer = DiskMapSunburstRenderer(
                    layout: layout, zoom: zoom, highlight: highlight,
                    selected: map.listSelection.compactMap { layout.arcIndex(of: $0) },
                    collected: map.collectedIDs
                )
                ZStack {
                    TimelineView(.animation(minimumInterval: nil, paused: zoom == nil)) { timeline in
                        Canvas { context, size in
                            renderer.draw(&context, size: size, now: timeline.date)
                        }
                    }
                    centerDisk(geometry: geometry, focus: focus, layout: layout, highlight: zoom == nil ? highlight : nil)
                }
                .contentShape(.rect)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    hover(phase, geometry: geometry, layout: layout, zooming: zoom != nil)
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    guard zoom == nil else { return }
                    tap(point, geometry: geometry, layout: layout)
                }
                .contextMenu {
                    if let node = map.hovered, !hoverCenter {
                        DiskMapNodeMenu(map: map, nodes: [node])
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: map.zoom?.date) {
                guard let zoom = map.zoom else { return }
                try? await Task.sleep(for: .seconds(DiskMapZoom.duration))
                map.endZoom(zoom)
            }
            .onChange(of: map.revision) { hoverArc = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gráfico de raios de sol de \(map.title(of: focus)), \(focus.size.formattedBytes)")
            .accessibilityHint("A lista ao lado mostra os mesmos itens, do maior para o menor.")
            .accessibilityAction(named: "Subir um nível") { map.goUp() }
        }
    }

    // MARK: - Centro

    private func centerDisk(geometry: DiskMapSunburstGeometry, focus: DiskMapNode, layout: DiskMapSunburstLayout,
                            highlight: Int?) -> some View {
        let diameter = geometry.hole * 2 - 8
        let goesUp = hoverCenter && map.canGoUp
        return ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(goesUp ? .regular.tint(Feature.diskMap.tint.opacity(0.22)) : .regular, in: .circle)
            centerLabel(focus: focus, layout: layout, highlight: highlight, goesUp: goesUp)
                .frame(width: diameter * 0.8)
        }
        .frame(width: max(diameter, 0), height: max(diameter, 0))
        .position(geometry.center)
        .allowsHitTesting(false)
        .animation(Motion.quick(reduceMotion), value: goesUp)
    }

    @ViewBuilder
    private func centerLabel(focus: DiskMapNode, layout: DiskMapSunburstLayout, highlight: Int?, goesUp: Bool) -> some View {
        let arc = highlight.flatMap { $0 < layout.arcs.count ? layout.arcs[$0] : nil }
        let title: String = {
            guard let arc else { return map.title(of: focus) }
            if let node = arc.node { return map.title(of: node) }
            return "\(arc.itemCount.formatted()) itens pequenos"
        }()
        let detail: String = {
            if goesUp { return "Clique para subir" }
            guard let arc else { return DiskMapFormat.files(focus.fileCount) }
            return "\(DiskMapFormat.percent(arc.size, of: focus.size)) de \(map.title(of: focus))"
        }()
        VStack(spacing: 3) {
            if goesUp {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Feature.diskMap.tint)
                    .transition(.scale.combined(with: .opacity))
            }
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
            Text((arc?.size ?? focus.size).formattedBytes)
                .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Ponteiro

    private func hover(_ phase: HoverPhase, geometry: DiskMapSunburstGeometry, layout: DiskMapSunburstLayout, zooming: Bool) {
        guard case .active(let point) = phase, !zooming, let hit = geometry.locate(point) else {
            clearHover()
            return
        }
        if hit.depth == 0 {
            if !hoverCenter || hoverArc != nil {
                hoverCenter = true
                hoverArc = nil
                map.hovered = nil
            }
            return
        }
        hoverCenter = false
        let index = layout.arcIndex(depth: hit.depth, angle: hit.angle)
        guard index != hoverArc else { return }
        hoverArc = index
        map.hovered = index.flatMap { layout.arcs[$0].node }
    }

    private func clearHover() {
        if hoverArc != nil { hoverArc = nil }
        if hoverCenter { hoverCenter = false }
        if map.hovered != nil { map.hovered = nil }
    }

    private func tap(_ point: CGPoint, geometry: DiskMapSunburstGeometry, layout: DiskMapSunburstLayout) {
        guard let hit = geometry.locate(point) else { return }
        if hit.depth == 0 {
            map.goUp()
            return
        }
        guard let index = layout.arcIndex(depth: hit.depth, angle: hit.angle) else { return }
        let arc = layout.arcs[index]
        switch arc.kind {
        case .directory:
            guard let node = arc.node else { return }
            if node.isNavigable, !node.children.isEmpty {
                map.open(node)
            } else {
                // Pasta vazia ou sem acesso: mostra na lista da pasta que a contém.
                if arc.parent !== map.focus { map.open(arc.parent) }
                map.listSelection = [node]
            }
        case .file, .synthetic:
            if let node = arc.node {
                if arc.parent !== map.focus { map.open(arc.parent) }
                map.listSelection = [node]
            }
        case .aggregate:
            if arc.parent !== map.focus { map.open(arc.parent) }
            if let node = arc.node { map.listSelection = [node] }
        case .merged:
            if arc.parent !== map.focus { map.open(arc.parent) }
        }
    }
}
