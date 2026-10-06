import AppKit
import CleanerCore
import SwiftUI

/// Estado do Mapa do disco: o que mapear, a árvore, a pasta em foco e o que foi coletado para remover.
@Observable
@MainActor
final class DiskMapModel: ScanningFeature {
    enum Target: Hashable, Sendable {
        case startupDisk
        case home
        case volume(URL)
        case folder(URL)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case sunburst, columns
        var id: String { rawValue }
        var title: String { self == .sunburst ? "Raios de sol" : "Colunas" }
    }

    struct Volume: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        let used: Int64
        var id: URL { url }
    }

    // MARK: Varredura

    /// O que o botão "Escanear" mapeia (padrão: pasta pessoal).
    var target: Target = .home
    /// O que a árvore atual mostra.
    private(set) var mappedTarget: Target?
    private(set) var isScanning = false
    private(set) var progress = DiskMapProgress.Snapshot()
    /// Bytes esperados (só em volumes externos, onde o usado do volume é o que vamos ler).
    private(set) var expectedBytes: Int64?
    private(set) var tree: DiskMapTree?

    // MARK: Navegação

    /// Pasta no centro do gráfico e dona da lista.
    private(set) var focus: DiskMapNode?
    private(set) var layout: DiskMapSunburstLayout?
    /// Filhos do foco (do maior para o menor), guardados para o `body` não recalcular.
    private(set) var rows: [DiskMapNode] = []
    private(set) var zoom: DiskMapZoom?
    /// Muda a cada alteração da árvore (remoção, arquivos pequenos abertos).
    private(set) var revision = 0
    var mode: Mode = .sunburst
    var listSelection: Set<DiskMapNode> = []
    /// Arquivo escolhido no modo Colunas.
    var leaf: DiskMapNode?
    /// Sob o ponteiro (no gráfico ou na lista).
    var hovered: DiskMapNode?
    private(set) var expanding: Set<ObjectIdentifier> = []

    // MARK: Coleta ("Para remover")

    private(set) var collected: [DiskMapNode] = []
    private(set) var collectedIDs: Set<ObjectIdentifier> = []
    private(set) var collectedBytes: Int64 = 0
    var collectorExpanded = false

    // MARK: Volumes

    private(set) var volumes: [Volume] = []
    private(set) var startupUsage = VolumeUsage.startup()

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var activeProgress: DiskMapProgress?
    /// Guarda o nó junto: enquanto está no cache, o endereço não é reaproveitado por outro nó.
    @ObservationIgnored private var verdicts: [ObjectIdentifier: (node: DiskMapNode, verdict: DiskMapRemovability)] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var badge: String? { nil }
    var summary: ScanSummary? { nil }

    init() {
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    // MARK: - Varredura

    /// Remapeia o alvo atual (padrão: pasta pessoal) e espera terminar.
    func scan() async {
        start()
        await scanTask?.value
    }

    func start(_ newTarget: Target? = nil) {
        let target = normalized(newTarget ?? self.target)
        let restoring = target == mappedTarget ? focus?.path : nil
        self.target = target
        scanTask?.cancel()
        activeProgress?.cancel()

        let progress = DiskMapProgress()
        activeProgress = progress
        self.progress = .init()
        // Usa o valor já lido em segundo plano: um volume de rede lento não trava a tela.
        if case .volume(let url) = target { expectedBytes = volumes.first { $0.url == url }?.used } else { expectedBytes = nil }
        isScanning = true
        hovered = nil
        zoom = nil
        let options = DiskMapScanOptions()
        let title = self.title(of: target)

        scanTask = Task { [weak self] in
            // Os contadores sobem no máximo 10×/s.
            let ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { break }
                    self?.progress = progress.snapshot
                }
            }
            let result = await Self.run(target, title: title, options: options, progress: progress)
            ticker.cancel()
            self?.finish(result, target: target, progress: progress, restoring: restoring)
        }
    }

    func cancel() {
        scanTask?.cancel()
        activeProgress?.cancel()
    }

    private nonisolated static func run(_ target: Target, title: String, options: DiskMapScanOptions,
                                        progress: DiskMapProgress) async -> DiskMapTree {
        switch target {
        case .startupDisk:
            await DiskMapScanner.scanStartupDisk(options: options, progress: progress)
        case .home:
            await DiskMapScanner.scan(Paths.home, kind: .home, title: title, options: options, progress: progress)
        case .volume(let url):
            await DiskMapScanner.scan(url, kind: .volume, title: title, options: options, progress: progress)
        case .folder(let url):
            await DiskMapScanner.scan(url, kind: .folder, title: title, options: options, progress: progress)
        }
    }

    private func finish(_ result: DiskMapTree, target: Target, progress: DiskMapProgress, restoring path: String?) {
        guard activeProgress === progress else { return }   // outra varredura já começou
        activeProgress = nil
        scanTask = nil
        isScanning = false
        self.progress = progress.snapshot
        // Parou uma atualização: o mapa anterior (completo) vale mais que um parcial.
        if result.isPartial, tree != nil {
            if let mappedTarget { self.target = mappedTarget }
            return
        }
        install(result, target: target, restoring: path)
    }

    private func install(_ tree: DiskMapTree, target: Target, restoring path: String?) {
        self.tree = tree
        mappedTarget = target
        verdicts = [:]
        collected = []
        syncCollected()
        collectorExpanded = false
        listSelection = []
        leaf = nil
        hovered = nil
        layout = nil
        focus = nil
        let restored = path.flatMap { tree.node(atPath: $0) }.flatMap { $0.isNavigable ? $0 : nil }
        show(restored ?? tree.root, animated: false)
    }

    // MARK: - Navegação

    /// Entra numa pasta (com zoom no gráfico).
    func open(_ node: DiskMapNode) {
        guard node.isNavigable else { return }
        show(node, animated: mode == .sunburst)
    }

    func goUp() {
        guard let parent = focus?.parent else { return }
        show(parent, animated: mode == .sunburst)
    }

    var canGoUp: Bool { focus?.parent != nil }

    /// Modo Colunas: escolher uma pasta abre a próxima coluna; um arquivo mostra os detalhes.
    func select(_ node: DiskMapNode?, inColumn directory: DiskMapNode) {
        guard let node else {
            show(directory, animated: false)
            leaf = nil
            return
        }
        if node.isNavigable {
            leaf = nil
            show(node, animated: false)
        } else {
            show(directory, animated: false)
            leaf = node
        }
    }

    func endZoom(_ zoom: DiskMapZoom) {
        if self.zoom?.date == zoom.date { self.zoom = nil }
    }

    private func show(_ node: DiskMapNode, animated: Bool) {
        guard let tree, tree.contains(node) else { return }
        guard node !== focus || layout == nil else { return }
        let previous = layout
        let next = DiskMapSunburstLayout(focus: node)
        zoom = nil
        if animated, let previous {
            if let window = DiskMapSunburst.window(of: node, in: previous.focus) {
                zoom = DiskMapZoom(other: previous, zoomingIn: true, start: window.start, end: window.end, depth: window.depth)
            } else if let window = DiskMapSunburst.window(of: previous.focus, in: node) {
                zoom = DiskMapZoom(other: previous, zoomingIn: false, start: window.start, end: window.end, depth: window.depth)
            }
        }
        focus = node
        layout = next
        rows = node.children
        listSelection = []
        if leaf?.parent !== node { leaf = nil }
        hovered = nil
        revision &+= 1
    }

    /// Depois de mudar a árvore: refaz lista e gráfico do foco, sem animação.
    private func refreshFocus() {
        guard let focus else { return }
        zoom = nil
        layout = DiskMapSunburstLayout(focus: focus)
        rows = focus.children
        revision &+= 1
    }

    // MARK: - Nomes

    func title(of node: DiskMapNode) -> String {
        node === tree?.root ? (tree?.title ?? node.displayName) : node.displayName
    }

    func title(of target: Target) -> String {
        switch target {
        case .startupDisk: startupUsage.name
        case .home: "Pasta pessoal"
        case .volume(let url): volumes.first { $0.url == url }?.name ?? url.lastPathComponent
        case .folder(let url): FileManager.default.displayName(atPath: url.path)
        }
    }

    func symbol(of target: Target) -> String {
        switch target {
        case .startupDisk: "internaldrive"
        case .home: "house"
        case .volume: "externaldrive"
        case .folder: "folder"
        }
    }

    // MARK: - Arquivos menores

    /// Troca o grupo "N arquivos menores" da pasta pela lista de verdade (lida agora).
    func expandSmallFiles(in directory: DiskMapNode, onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        guard let tree, directory.aggregateChild != nil else { return }
        let key = ObjectIdentifier(directory)
        guard !expanding.contains(key) else { return }
        expanding.insert(key)
        let names = Set(directory.children.filter { !$0.isAggregate && !$0.isSynthetic }.map(\.name))
        let path = directory.path
        let keepLink = tree.linkFilter(for: directory)
        Task { [weak self] in
            let files = await DiskMapScanner.listFiles(inDirectoryAt: path, skipping: names, keepLink: keepLink)
            guard let self else { return }
            self.expanding.remove(key)
            guard self.tree === tree, tree.contains(directory) else { return }
            guard let files else {
                onFailure("Não foi possível ler a pasta \(directory.displayName)")
                return
            }
            tree.replaceAggregate(in: directory, with: files)
            self.listSelection = self.listSelection.filter { tree.contains($0) }
            if let leaf = self.leaf, !tree.contains(leaf) { self.leaf = nil }
            self.verdicts = [:]
            // Uma pasta coletada pode ter mudado de tamanho com a leitura nova.
            self.syncCollected()
            self.refreshFocus()
        }
    }

    // MARK: - Coleta

    /// Pode ir para a remoção? Calculado uma vez por item (o `SafetyGuard` toca no disco).
    func removability(_ node: DiskMapNode) -> DiskMapRemovability {
        guard let tree else { return .blocked("Sem mapa") }
        let key = ObjectIdentifier(node)
        if let cached = verdicts[key], cached.node === node { return cached.verdict }
        let verdict = tree.removability(of: node)
        verdicts[key] = (node, verdict)
        return verdict
    }

    /// URL para Finder e Quick Look (caminho de sempre quando existe).
    func revealURL(_ node: DiskMapNode) -> URL? {
        guard !node.isAggregate, !node.isSynthetic else { return nil }
        return removability(node).url ?? DiskMapPaths.revealURL(forPhysicalPath: node.path)
    }

    func isCollected(_ node: DiskMapNode) -> Bool {
        guard !collectedIDs.isEmpty else { return false }
        var current: DiskMapNode? = node
        while let item = current {
            if collectedIDs.contains(ObjectIdentifier(item)) { return true }
            current = item.parent
        }
        return false
    }

    func collect(_ nodes: [DiskMapNode]) {
        var added = 0
        for node in nodes where removability(node).url != nil && !isCollected(node) {
            // A pasta leva tudo o que está dentro.
            collected.removeAll { $0.isDescendant(of: node) }
            collected.append(node)
            syncCollected()
            added += 1
        }
        if added > 0 { collectorExpanded = true }
    }

    func uncollect(_ node: DiskMapNode) {
        collected.removeAll { $0 === node }
        syncCollected()
    }

    func clearCollected() {
        collected = []
        syncCollected()
    }

    private func syncCollected() {
        collectedIDs = Set(collected.map(ObjectIdentifier.init))
        collectedBytes = collected.reduce(0) { $0 + $1.size }
        if collected.isEmpty { collectorExpanded = false }
    }

    /// Itens da coleta conferidos agora (o disco pode ter mudado desde a varredura).
    /// `skipped` conta os que deixaram de poder sair (ficam na lista, marcados).
    func removalBatch() -> (items: [RemovalItem], nodes: [URL: DiskMapNode], skipped: Int) {
        var items: [RemovalItem] = []
        var nodes: [URL: DiskMapNode] = [:]
        var skipped = 0
        for node in collected {
            verdicts[ObjectIdentifier(node)] = nil
            guard let url = removability(node).url, nodes[url] == nil else {
                skipped += 1
                continue
            }
            items.append(RemovalItem(url: url, size: node.size))
            nodes[url] = node
        }
        return (items, nodes, skipped)
    }

    /// Tira da árvore o que o `Remover` levou e desconta dos totais.
    func applyRemoval(_ report: RemovalReport, nodes: [URL: DiskMapNode]) {
        let removed = report.removedSet
        detach(nodes.filter { removed.contains($0.key) }.map(\.value))
    }

    /// Pasta que o usuário mandou ignorar (já foi para Ajustes ▸ Ignorar): sai do mapa.
    func ignore(_ node: DiskMapNode) {
        detach([node])
    }

    private func detach(_ nodes: [DiskMapNode]) {
        guard let tree, !nodes.isEmpty else { return }
        var newFocus = focus
        for node in nodes where tree.contains(node) && node !== tree.root {
            if let current = newFocus, current === node || current.isDescendant(of: node) { newFocus = node.parent }
            tree.remove(node)
        }
        collected.removeAll { !tree.contains($0) }
        syncCollected()
        verdicts = [:]
        listSelection = listSelection.filter { tree.contains($0) }
        if let leaf, !tree.contains(leaf) { self.leaf = nil }
        hovered = nil
        if let newFocus { focus = newFocus }
        refreshFocus()
    }

    /// Caminho arrastado para fora (Finder, Terminal): o que o usuário conhece, sem o prefixo do volume de dados.
    nonisolated static func dragPayload(for node: DiskMapNode) -> String {
        DiskMapPaths.displayPath(forPhysicalPath: node.path)
    }

    // MARK: - Alvos

    /// Pasta solta na tela: se já está no mapa, entra nela; senão, mapeia.
    func handleDrop(_ urls: [URL]) -> Bool {
        guard !isScanning else { return false }
        guard let url = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true })
        else { return false }
        if let tree, let node = tree.node(atPath: url.standardizedFileURL.path), node.isNavigable {
            mode == .sunburst ? open(node) : select(node, inColumn: node.parent ?? node)
            return true
        }
        start(.folder(url))
        return true
    }

    private func normalized(_ target: Target) -> Target {
        guard case .folder(let url) = target else { return target }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path == "/" || path == DiskMapPaths.dataVolumePrefix { return .startupDisk }
        if path == Paths.home.resolvingSymlinksInPath().standardizedFileURL.path { return .home }
        if let volume = volumes.first(where: { $0.url.standardizedFileURL.path == path }) { return .volume(volume.url) }
        return .folder(URL(fileURLWithPath: path, isDirectory: true))
    }

    func refreshVolumes() {
        Task { [weak self] in
            // Volume de rede pode demorar a responder: lê fora da main.
            let (startup, list) = await Task.detached(priority: .utility) {
                (VolumeUsage.startup(), DiskMapModel.listVolumes())
            }.value
            self?.startupUsage = startup
            self?.volumes = list
        }
    }

    private nonisolated static func listVolumes() -> [Volume] {
        VolumeUsage.mountedVolumes().compactMap { url in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix("/Volumes/") else { return nil }
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
            return Volume(url: url, name: name, used: VolumeUsage.of(url).used)
        }
    }
}

/// Zoom do gráfico entre duas pastas: o desenho de antes e onde o foco novo fica dentro dele
/// (entrando) ou onde o foco antigo fica dentro do novo (saindo).
struct DiskMapZoom {
    let other: DiskMapSunburstLayout
    let zoomingIn: Bool
    let start: Double
    let end: Double
    let depth: Int
    let date = Date()

    static let duration: TimeInterval = 0.62

    /// 0…1 com a curva das molas da casa (amortecimento crítico, resposta ~0,42 s).
    func progress(at now: Date) -> Double {
        let t = now.timeIntervalSince(date)
        guard t > 0 else { return 0 }
        guard t < Self.duration else { return 1 }
        let omega = 2 * Double.pi / 0.42
        return min(1, 1 - (1 + omega * t) * exp(-omega * t))
    }
}
