import AppKit
import CleanerCore
import SwiftUI

/// Textos curtos do mapa.
enum DiskMapFormat {
    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0, part > 0 else { return "—" }
        let value = Double(part) / Double(whole)
        if value < 0.001 { return "<" + (0.001).formatted(.percent.precision(.fractionLength(1))) }
        return value.formatted(.percent.precision(.fractionLength(value < 0.1 ? 1 : 0)))
    }

    static func files(_ count: Int) -> String {
        count == 1 ? "1 arquivo" : "\(count.formatted()) arquivos"
    }

    /// Caminho como o usuário conhece, com ~ no lugar da pasta pessoal.
    static func shortPath(_ physical: String) -> String {
        let shown = DiskMapPaths.displayPath(forPhysicalPath: physical)
        let home = Paths.home.path
        if shown == home { return "~" }
        if shown.hasPrefix(home + "/") { return "~" + shown.dropFirst(home.count) }
        return shown
    }

    static func items(_ node: DiskMapNode) -> String {
        if node.isSynthetic { return "—" }
        if node.isRestricted { return "sem acesso" }
        if node.isDataless { return "na nuvem" }
        return node.isDirectory || node.isAggregate ? files(node.fileCount) : ""
    }
}

/// Ícone do item com selo de estado (sem acesso, só na nuvem, atalho).
struct DiskMapNodeIcon: View {
    let map: DiskMapModel
    let node: DiskMapNode
    var size: CGFloat = 20

    var body: some View {
        Group {
            if node.isAggregate {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.secondary)
            } else if node.isSynthetic {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(.secondary)
            } else if let url = map.revealURL(node) {
                FileIcon(url: url, size: size)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: max(8, size * 0.38), weight: .bold))
                    .foregroundStyle(node.isRestricted ? Brand.orange : .secondary)
                    .padding(1.5)
                    .background(Circle().fill(.background))
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var badge: String? {
        if node.isRestricted { return "lock.fill" }
        if node.isDataless { return "icloud" }
        if node.isSymlink { return "arrow.turn.up.right" }
        return nil
    }
}

/// Barra proporcional ao tamanho.
struct DiskMapSizeBar: View {
    let fraction: Double
    let color: Color
    var width: CGFloat = 150

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule()
                .fill(color.gradient)
                .frame(width: max(fraction > 0 ? 3 : 0, width * min(1, fraction)))
        }
        .frame(width: width, height: 5)
    }
}

/// Menu de contexto dos itens do mapa (lista, colunas e gráfico).
struct DiskMapNodeMenu: View {
    let map: DiskMapModel
    let nodes: [DiskMapNode]

    @Environment(AppModel.self) private var app

    var body: some View {
        if nodes.count == 1, let node = nodes.first {
            if node.isNavigable, node !== map.focus {
                Button("Abrir") { map.mode == .sunburst ? map.open(node) : map.select(node, inColumn: node.parent ?? node) }
            }
            if node.isAggregate, let parent = node.parent {
                Button("Mostrar os arquivos menores") { expand(parent) }
            }
            if let url = map.revealURL(node) {
                FileContextMenu(url: url, onIgnore: node.isNavigable && map.removability(node).url != nil ? { map.ignore(node) } : nil)
            }
            Divider()
        }
        collectSection
    }

    @ViewBuilder private var collectSection: some View {
        let fresh = nodes.filter { !map.isCollected($0) }
        let allowed = fresh.filter { map.removability($0).url != nil }
        if nodes.count == 1, let node = nodes.first, map.collectedIDs.contains(ObjectIdentifier(node)) {
            Button("Tirar da lista para remover") { map.uncollect(node) }
        } else if fresh.isEmpty, !nodes.isEmpty {
            Text("Já está na lista para remover")
        } else if allowed.isEmpty {
            Button("Mover para a remoção") {}.disabled(true)
        } else {
            Button(allowed.count == 1 ? "Mover para a remoção" : "Mover \(allowed.count) itens para a remoção") {
                map.collect(allowed)
            }
        }
        if allowed.count < fresh.count, let reason = fresh.lazy.compactMap({ map.removability($0).reason }).first {
            Text(fresh.count == 1 ? "Protegido: \(reason)" : "Alguns itens estão protegidos: \(reason)")
        }
    }

    private func expand(_ directory: DiskMapNode) {
        map.expandSmallFiles(in: directory) { message in
            app.showToast(message, symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }
}

// MARK: - Caminho

/// Barra de caminho clicável (da raiz mapeada até o foco) com o botão de subir.
struct DiskMapPathBar: View {
    let map: DiskMapModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                map.goUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(!map.canGoUp)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Subir um nível (⌘↑)")
            .accessibilityLabel("Subir um nível")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let chain = map.focus?.chain ?? []
                        ForEach(Array(chain.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            crumb(node, isLast: index == chain.count - 1, isRoot: index == 0)
                                .id(node.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: map.focus) {
                    if let id = map.focus?.id { proxy.scrollTo(id, anchor: .trailing) }
                }
            }

            Spacer(minLength: 8)
            if let tree = map.tree {
                if tree.isPartial {
                    Label("Parcial", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.orange)
                        .help("A varredura foi interrompida: os tamanhos estão incompletos.")
                }
                if tree.restrictedCount > 0 {
                    Label("\(tree.restrictedCount.formatted()) sem acesso", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Pastas que o macOS não deixou ler. Com o Acesso Total ao Disco, quase todas aparecem.")
                }
            }
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
    }

    private func crumb(_ node: DiskMapNode, isLast: Bool, isRoot: Bool) -> some View {
        Button {
            map.mode == .sunburst ? map.open(node) : map.select(node, inColumn: node.parent ?? node)
        } label: {
            HStack(spacing: 5) {
                if isRoot, let target = map.mappedTarget {
                    Image(systemName: map.symbol(of: target)).foregroundStyle(Feature.diskMap.tint)
                } else {
                    DiskMapNodeIcon(map: map, node: node, size: 15)
                }
                Text(map.title(of: node))
                    .lineLimit(1)
                    .fontWeight(isLast ? .semibold : .regular)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(isLast ? Feature.diskMap.tint.opacity(0.14) : .clear))
            .foregroundStyle(isLast ? .primary : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(isLast)
        .help(DiskMapFormat.shortPath(node.path))
    }
}

// MARK: - Lista

/// Filhos da pasta em foco, do maior para o menor (estilo OmniDiskSweeper).
struct DiskMapListView: View {
    let map: DiskMapModel

    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var map = map
        VStack(spacing: 0) {
            if let focus = map.focus {
                header(focus)
                Divider()
                if map.rows.isEmpty {
                    empty(focus)
                } else {
                    let largest = map.rows.first?.size ?? 0
                    List(selection: $map.listSelection) {
                        ForEach(map.rows) { node in
                            DiskMapListRow(map: map, node: node, parentSize: focus.size, largest: largest,
                                           color: rowColor(node))
                                .tag(node)
                        }
                    }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds()
                    .contextMenu(forSelectionType: DiskMapNode.self) { nodes in
                        DiskMapNodeMenu(map: map, nodes: sorted(nodes))
                    } primaryAction: { nodes in
                        primary(sorted(nodes))
                    }
                    .onDeleteCommand { map.collect(sorted(map.listSelection)) }
                }
            }
        }
    }

    private func header(_ focus: DiskMapNode) -> some View {
        HStack(spacing: 10) {
            Text("\(map.rows.count.formatted()) \(map.rows.count == 1 ? "item" : "itens") em \(map.title(of: focus))")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("%").frame(width: 52, alignment: .trailing)
            Text("Conteúdo").frame(width: 92, alignment: .trailing)
            Text("Tamanho").frame(width: 84, alignment: .trailing)
            Color.clear.frame(width: 22, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
        .padding(.trailing, 18)
        .padding(.vertical, 7)
    }

    @ViewBuilder private func empty(_ focus: DiskMapNode) -> some View {
        if focus.isRestricted {
            ContentUnavailableView("Sem permissão de leitura", systemImage: "lock.fill",
                                   description: Text("O macOS não deixou ler esta pasta. Conceda o Acesso Total ao Disco e mapeie de novo."))
        } else if focus.isDataless {
            ContentUnavailableView("Só na nuvem", systemImage: "icloud",
                                   description: Text("O conteúdo desta pasta não está baixado neste Mac."))
        } else {
            ContentUnavailableView("Pasta vazia", systemImage: "folder",
                                   description: Text("Não há nada aqui ocupando espaço."))
        }
    }

    private func rowColor(_ node: DiskMapNode) -> Color {
        if node.isAggregate { return DiskMapPalette.smallFiles }
        if node.isSynthetic { return DiskMapPalette.system }
        if let index = map.layout?.arcIndex(of: node), let arc = map.layout?.arcs[index] {
            return DiskMapPalette.color(for: arc)
        }
        return DiskMapPalette.merged
    }

    private func sorted(_ nodes: Set<DiskMapNode>) -> [DiskMapNode] {
        nodes.sorted(by: { $0.size > $1.size })
    }

    /// Duplo clique / Return: entra na pasta, abre os arquivos menores ou mostra no Quick Look.
    private func primary(_ nodes: [DiskMapNode]) {
        if nodes.count == 1, let node = nodes.first {
            if node.isNavigable { map.open(node); return }
            if node.isAggregate, let parent = node.parent {
                map.expandSmallFiles(in: parent) { app.showToast($0, symbol: "exclamationmark.triangle.fill", isError: true) }
                return
            }
        }
        let urls = nodes.filter { !$0.isDirectory }.compactMap { map.revealURL($0) }
        if !urls.isEmpty { Reveal.quickLook(urls) }
    }
}

/// Linha da lista: ícone, nome, barra proporcional, % da pasta, conteúdo e tamanho.
struct DiskMapListRow: View {
    let map: DiskMapModel
    let node: DiskMapNode
    let parentSize: Int64
    let largest: Int64
    let color: Color

    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let collected = map.isCollected(node)
        HStack(spacing: 10) {
            DiskMapNodeIcon(map: map, node: node, size: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(map.title(of: node))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(collected, color: .secondary)
                DiskMapSizeBar(fraction: largest > 0 ? Double(node.size) / Double(largest) : 0, color: color, width: 130)
            }
            .help(help)
            Spacer(minLength: 6)
            if node.isAggregate {
                if let parent = node.parent, map.expanding.contains(ObjectIdentifier(parent)) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Mostrar") {
                        if let parent = node.parent {
                            map.expandSmallFiles(in: parent) { app.showToast($0, symbol: "exclamationmark.triangle.fill", isError: true) }
                        }
                    }
                    .controlSize(.small)
                    .help("Listar um por um os arquivos menores desta pasta")
                }
            }
            Text(DiskMapFormat.percent(node.size, of: parentSize))
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(DiskMapFormat.items(node))
                .frame(width: 92, alignment: .trailing)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SizeText(bytes: node.size)
                .frame(width: 84, alignment: .trailing)
            collectControl(collected: collected)
                .frame(width: 22)
        }
        .font(.callout.monospacedDigit())
        .padding(.vertical, 3)
        .opacity(collected ? 0.55 : 1)
        .contentShape(.rect)
        .onHover { inside in
            hovering = inside
            if inside { map.hovered = node } else if map.hovered === node { map.hovered = nil }
        }
        .onDrag { NSItemProvider(object: DiskMapModel.dragPayload(for: node) as NSString) }
    }

    private var help: String {
        if node.isSynthetic {
            return "Volume do macOS (selado), instantâneos, memória virtual, espaço purgeable e o que não deu para ler. Não dá para remover daqui."
        }
        if node.isAggregate { return "Arquivos abaixo de 1 MB somados. Clique em Mostrar para ver um por um." }
        if node.isRestricted { return "Sem permissão de leitura: conceda o Acesso Total ao Disco." }
        if node.isDataless { return "Só na nuvem: não ocupa espaço neste Mac." }
        return DiskMapFormat.shortPath(node.path)
    }

    @ViewBuilder private func collectControl(collected: Bool) -> some View {
        if collected {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(Feature.diskMap.tint)
                .help("Na lista para remover")
                .accessibilityLabel("Na lista para remover")
        } else if hovering, !node.isAggregate {
            if let reason = map.removability(node).reason {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(.quaternary)
                    .help("Não pode ser removido: \(reason)")
                    .accessibilityLabel("Protegido: \(reason)")
            } else {
                Button {
                    map.collect([node])
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Mover para a remoção")
                .accessibilityLabel("Mover para a remoção")
            }
        }
    }
}
