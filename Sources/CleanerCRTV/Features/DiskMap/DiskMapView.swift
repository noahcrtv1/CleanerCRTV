import AppKit
import CleanerCore
import SwiftUI
import UniformTypeIdentifiers

/// Mapa do disco: raios de sol + lista (ou colunas), com coleta do que remover.
struct DiskMapView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false

    private var map: DiskMapModel { app.diskMap }

    var body: some View {
        @Bindable var map = map
        VStack(spacing: 0) {
            FeatureHeader(feature: .diskMap, subtitle: map.tree.map { "\($0.title) · \($0.root.size.formattedBytes)" }) {
                if map.tree != nil, !map.isScanning {
                    Picker("Modo", selection: $map.mode) {
                        ForEach(DiskMapModel.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                targetMenu
                Button {
                    map.start()
                } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }
                .disabled(map.isScanning)
                .keyboardShortcut("r", modifiers: .command)
                .help("Mapear de novo (⌘R)")
            }
            content
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Feature.diskMap.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            map.handleDrop(urls)
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: - Alvo

    private var targetMenu: some View {
        Menu {
            Button { map.start(.startupDisk) } label: {
                Label("Disco de inicialização", systemImage: "internaldrive")
            }
            Button { map.start(.home) } label: {
                Label("Pasta pessoal", systemImage: "house")
            }
            if !map.volumes.isEmpty {
                Section("Volumes") {
                    ForEach(map.volumes) { volume in
                        Button { map.start(.volume(volume.url)) } label: {
                            Label("\(volume.name) · \(volume.used.formattedBytes)", systemImage: "externaldrive")
                        }
                    }
                }
            }
            Divider()
            Button("Escolher pasta…") { chooseFolder() }
        } label: {
            Label(map.title(of: map.mappedTarget ?? map.target), systemImage: map.symbol(of: map.mappedTarget ?? map.target))
        }
        .fixedSize()
        .disabled(map.isScanning)
        .help("O que mapear")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Mapear"
        panel.message = "Escolha a pasta que você quer mapear"
        if panel.runModal() == .OK, let url = panel.url { map.start(.folder(url)) }
    }

    // MARK: - Conteúdo

    @ViewBuilder private var content: some View {
        if map.isScanning {
            ScanningView(title: "Mapeando \(map.title(of: map.target))…",
                         detail: map.progress.currentPath.isEmpty ? nil : DiskMapFormat.shortPath(map.progress.currentPath),
                         progress: scanFraction,
                         counter: "\(map.progress.files.formatted()) arquivos · \(map.progress.directories.formatted()) pastas · \(map.progress.bytes.formattedBytes)",
                         onCancel: { map.cancel() })
        } else if map.tree == nil {
            hero
        } else {
            VStack(spacing: 0) {
                DiskMapPathBar(map: map)
                Divider()
                Group {
                    switch map.mode {
                    case .sunburst:
                        HSplitView {
                            DiskMapSunburstView(map: map)
                                .padding(20)
                                .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                            DiskMapListView(map: map)
                                .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .columns:
                        DiskMapColumnsView(map: map)
                    }
                }
                .transition(.opacity)
                .animation(Motion.standard(reduceMotion), value: map.mode)
                DiskMapCollectorBar(map: map)
            }
        }
    }

    private var scanFraction: Double? {
        guard let expected = map.expectedBytes, expected > 0 else { return nil }
        return min(1, Double(map.progress.bytes) / Double(expected))
    }

    private var hero: some View {
        VStack(spacing: 0) {
            ScanHero(symbol: Feature.diskMap.symbol, tint: Feature.diskMap.tint,
                     title: "Veja o que ocupa o seu disco",
                     message: "Mapeie a pasta pessoal, o disco inteiro ou um volume externo e descubra as pastas e arquivos que mais ocupam espaço. Você também pode arrastar uma pasta para cá.",
                     buttonTitle: "Mapear pasta pessoal") { map.start(.home) }
            HStack(spacing: 10) {
                Button { map.start(.startupDisk) } label: {
                    Label("Disco de inicialização", systemImage: "internaldrive")
                }
                ForEach(map.volumes) { volume in
                    Button { map.start(.volume(volume.url)) } label: {
                        Label(volume.name, systemImage: "externaldrive")
                    }
                }
                Button { chooseFolder() } label: {
                    Label("Escolher pasta…", systemImage: "folder")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Colunas

/// Colunas estilo OmniDiskSweeper: cada pasta escolhida abre a próxima à direita.
struct DiskMapColumnsView: View {
    let map: DiskMapModel

    @Environment(AppModel.self) private var app

    var body: some View {
        let chain = map.focus?.chain ?? []
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(chain.enumerated()), id: \.element.id) { index, directory in
                        DiskMapColumn(map: map, directory: directory,
                                      selected: index + 1 < chain.count ? chain[index + 1] : map.leaf)
                            .frame(width: 290)
                            .id(directory.id)
                        Divider()
                    }
                    if let leaf = map.leaf {
                        DiskMapLeafDetail(map: map, node: leaf)
                            .frame(width: 260)
                            .id("leaf")
                    }
                }
            }
            .onChange(of: map.focus) { scroll(proxy) }
            .onChange(of: map.leaf) { scroll(proxy) }
            .onAppear { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if map.leaf != nil {
            proxy.scrollTo("leaf", anchor: .trailing)
        } else if let id = map.focus?.id {
            proxy.scrollTo(id, anchor: .trailing)
        }
    }
}

private struct DiskMapColumn: View {
    let map: DiskMapModel
    let directory: DiskMapNode
    let selected: DiskMapNode?

    @Environment(AppModel.self) private var app

    var body: some View {
        // Revision força a releitura dos filhos depois de remoções ou de abrir os arquivos menores.
        let _ = map.revision
        let children = directory.children
        let largest = children.first?.size ?? 0
        List(selection: Binding<DiskMapNode?>(
            get: { selected },
            set: { map.select($0, inColumn: directory) }
        )) {
            ForEach(children) { node in
                row(node, largest: largest)
                    .tag(node)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: DiskMapNode.self) { nodes in
            DiskMapNodeMenu(map: map, nodes: nodes.sorted { $0.size > $1.size })
        } primaryAction: { nodes in
            guard nodes.count == 1, let node = nodes.first else { return }
            if node.isAggregate {
                map.expandSmallFiles(in: directory) { app.showToast($0, symbol: "exclamationmark.triangle.fill", isError: true) }
            } else if !node.isDirectory, let url = map.revealURL(node) {
                Reveal.quickLook([url])
            }
        }
        .overlay {
            if children.isEmpty {
                ContentUnavailableView(directory.isRestricted ? "Sem acesso" : "Vazia",
                                       systemImage: directory.isRestricted ? "lock.fill" : "folder")
            }
        }
    }

    private func row(_ node: DiskMapNode, largest: Int64) -> some View {
        HStack(spacing: 8) {
            DiskMapNodeIcon(map: map, node: node, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(map.title(of: node))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(map.isCollected(node), color: .secondary)
                DiskMapSizeBar(fraction: largest > 0 ? Double(node.size) / Double(largest) : 0,
                               color: node.isAggregate ? DiskMapPalette.smallFiles : Feature.diskMap.tint, width: 110)
            }
            Spacer(minLength: 4)
            SizeText(bytes: node.size)
                .font(.callout.monospacedDigit())
            if node.isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(map.isCollected(node) ? 0.55 : 1)
        .help(DiskMapFormat.shortPath(node.path))
    }
}

/// Coluna final com os detalhes do arquivo escolhido.
private struct DiskMapLeafDetail: View {
    let map: DiskMapModel
    let node: DiskMapNode

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            DiskMapNodeIcon(map: map, node: node, size: 72)
                .padding(.top, 30)
            Text(map.title(of: node))
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(node.size.formattedBytes)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
            if let parent = node.parent {
                Text("\(DiskMapFormat.percent(node.size, of: parent.size)) de \(map.title(of: parent))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if node.isAggregate {
                Text(DiskMapFormat.files(node.fileCount)).font(.caption).foregroundStyle(.secondary)
                if let parent = node.parent {
                    Button("Mostrar um por um") {
                        map.expandSmallFiles(in: parent) { app.showToast($0, symbol: "exclamationmark.triangle.fill", isError: true) }
                    }
                    .controlSize(.small)
                    .disabled(map.expanding.contains(ObjectIdentifier(parent)))
                }
            }
            if let url = map.revealURL(node) {
                HStack {
                    Button("Mostrar no Finder") { Reveal.inFinder([url]) }
                    Button { Reveal.quickLook([url]) } label: { Image(systemName: "eye") }
                        .accessibilityLabel("Visualização rápida")
                        .help("Visualização rápida")
                }
                .controlSize(.small)
                let reason = map.removability(node).reason
                Button("Mover para a remoção") { map.collect([node]) }
                    .buttonStyle(.tinted(Feature.diskMap.tint))
                    .disabled(reason != nil || map.isCollected(node))
                    .help(reason.map { "Não pode ser removido: \($0)" } ?? "Adicionar à lista para remover")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Para remover

/// Gaveta "Para remover" (como no DaisyDisk) + barra de ação.
struct DiskMapCollectorBar: View {
    let map: DiskMapModel

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var map = map
        VStack(spacing: 0) {
            if map.collectorExpanded, !map.collected.isEmpty {
                drawer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ActionBar(summary: summary,
                      buttonTitle: map.collected.isEmpty ? "Remover" : "Remover \(map.collected.count) \(map.collected.count == 1 ? "item" : "itens") · \(map.collectedBytes.formattedBytes)",
                      enabled: !map.collected.isEmpty) {
                Button {
                    map.collectorExpanded.toggle()
                } label: {
                    Label("Para remover", systemImage: map.collectorExpanded ? "chevron.down" : "tray.full")
                }
                .buttonStyle(.borderless)
                .disabled(map.collected.isEmpty)
                .help(map.collectorExpanded ? "Esconder a lista" : "Mostrar a lista do que vai ser removido")
                if !map.collected.isEmpty {
                    Button("Limpar") { map.clearCollected() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            } action: {
                remove()
            }
        }
        .animation(Motion.standard(reduceMotion), value: map.collectorExpanded)
        .animation(Motion.standard(reduceMotion), value: map.collected.count)
    }

    private var summary: String {
        map.collected.isEmpty
            ? "Clique com o botão direito num item e escolha Mover para a remoção"
            : "\(map.collectedBytes.formattedBytes) para liberar"
    }

    private var drawer: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(map.collected) { node in
                    HStack(spacing: 10) {
                        DiskMapNodeIcon(map: map, node: node, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(map.title(of: node)).lineLimit(1)
                            Text(DiskMapFormat.shortPath(node.path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if let reason = map.removability(node).reason {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Brand.orange)
                                .help("Ficará de fora: \(reason)")
                                .accessibilityLabel("Ficará de fora: \(reason)")
                        }
                        SizeText(bytes: node.size).font(.callout.monospacedDigit())
                        Button {
                            map.uncollect(node)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Tirar da lista")
                        .accessibilityLabel("Tirar \(map.title(of: node)) da lista")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
                    .contextMenu {
                        if let url = map.revealURL(node) { FileContextMenu(url: url) }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: min(220, CGFloat(map.collected.count) * 40 + 12))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func remove() {
        let batch = map.removalBatch()
        guard !batch.items.isEmpty else {
            app.showToast("Os itens da lista não podem mais ser removidos.", symbol: "exclamationmark.triangle.fill", isError: true)
            return
        }
        let note = batch.skipped == 0 ? nil
            : "\(batch.skipped) \(batch.skipped == 1 ? "item da lista mudou e ficou" : "itens da lista mudaram e ficaram") de fora."
        app.requestRemoval(batch.items, source: Feature.diskMap.title,
                           title: "Remover \(batch.items.count) \(batch.items.count == 1 ? "item" : "itens") do mapa?",
                           note: note) { report in
            map.applyRemoval(report, nodes: batch.nodes)
        }
    }
}
