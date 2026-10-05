import AppKit
import CleanerCore
import SwiftUI

/// Estado do "Lixo do sistema": varredura, seleção e totais.
/// Totais e contagens ficam guardados e são ajustados a cada mudança, para listas de 10 mil itens não pesarem.
@Observable
@MainActor
final class CleanupModel: ScanningFeature {
    /// Uma categoria com o que foi achado nela (só categorias com itens aparecem).
    struct CategoryResult: Identifiable {
        let category: CleanupCategory
        /// Do maior para o menor.
        var entries: [CleanupEntry]
        var bytes: Int64 = 0
        var runningCount = 0
        var id: CleanupCategoryID { category.id }
        var isTrash: Bool { category.isTrash }

        init(category: CleanupCategory, entries: [CleanupEntry]) {
            self.category = category
            self.entries = entries
            recount()
        }

        mutating func recount() {
            bytes = entries.reduce(0) { $0 + $1.size }
            runningCount = entries.reduce(0) { $0 + ($1.isAppRunning || $1.isActive ? 1 : 0) }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case size, name
        var id: String { rawValue }
        var title: String { self == .size ? "Tamanho" : "Nome" }
    }

    // MARK: - Estado

    private(set) var isScanning = false
    private(set) var progress: CleanupScanProgress?
    private(set) var results: [CleanupCategoryResult] = []
    /// nil até a primeira varredura terminar.
    private(set) var lastScan: Date?
    /// Pastas que não puderam ser lidas (sem Acesso Total ao Disco).
    private(set) var inaccessibleCount = 0

    /// Itens marcados (nunca inclui a Lixeira).
    private(set) var selection: Set<URL> = []
    private(set) var selectedCount = 0
    private(set) var selectedBytes: Int64 = 0
    private(set) var selectedPerCategory: [CleanupCategoryID: Int] = [:]

    /// Tudo o que foi achado, sem a Lixeira.
    private(set) var totalBytes: Int64 = 0
    private(set) var totalCount = 0
    private(set) var trashBytes: Int64 = 0
    private(set) var trashCount = 0

    /// Categoria aberta no painel da direita.
    var focused: CleanupCategoryID? {
        didSet { if oldValue != focused { refreshVisible() } }
    }
    var sortOrder: SortOrder = .size {
        didSet { if oldValue != sortOrder { refreshVisible() } }
    }
    /// Itens da categoria aberta, já na ordem escolhida.
    private(set) var visibleEntries: [CleanupEntry] = []

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var trashTask: Task<Void, Never>?

    init() {}

    // MARK: - Painel (ScanningFeature)

    var badge: String? {
        guard lastScan != nil, totalBytes > 0 else { return nil }
        return totalBytes.formattedBytes
    }

    var summary: ScanSummary? {
        guard lastScan != nil else { return nil }
        let detail = trashBytes > 0 ? "Lixeira com \(trashBytes.formattedBytes)" : nil
        return ScanSummary(title: Feature.cleanup.title, bytes: totalBytes, count: totalCount, detail: detail)
    }

    /// Itens marcados, sem a Lixeira (o Painel limpa exatamente isto e depois chama `didRemove`).
    var recommendedItems: [RemovalItem] {
        results.filter { !$0.isTrash }.flatMap(\.entries)
            .filter { selection.contains($0.url) }
            .map(\.removalItem)
    }

    /// Conteúdo da Lixeira, para "Esvaziar Lixeira".
    var trashItems: [RemovalItem] {
        results.first { $0.isTrash }?.entries.map(\.removalItem) ?? []
    }

    var hasResults: Bool { lastScan != nil }

    // MARK: - Varredura

    func scan() async {
        if let scanTask {
            await scanTask.value
            return
        }
        isScanning = true
        progress = nil
        let options = CleanupScanner.Options(
            runningBundleIDs: RunningApps.bundleIdentifiers,
            runningAppNames: Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName)),
            hasFullDiskAccess: FullDiskAccess.isGranted
        )
        let task = Task { [weak self] in
            let result = await CleanupScanner().scan(options) { progress in
                Task { @MainActor in self?.receive(progress) }
            }
            self?.finish(result)
        }
        scanTask = task
        await task.value
    }

    func cancel() {
        scanTask?.cancel()
    }

    private func receive(_ progress: CleanupScanProgress) {
        guard isScanning else { return }
        self.progress = progress
    }

    private func finish(_ result: CleanupScanResult) {
        scanTask = nil
        isScanning = false
        progress = nil
        // Cancelada: o resultado anterior (se houver) continua valendo.
        guard !result.wasCancelled else { return }
        trashTask?.cancel()
        inaccessibleCount = result.inaccessibleCount
        apply(result.entries)
        lastScan = Date()
    }

    private func apply(_ entries: [CleanupEntry]) {
        let grouped = Dictionary(grouping: entries, by: \.category)
        results = CleanupCatalog.all.compactMap { category in
            guard let list = grouped[category.id], !list.isEmpty else { return nil }
            return CategoryResult(category: category, entries: list.sorted(by: Self.bySize))
        }
        selection = Set(entries.lazy.filter { $0.isRecommended && $0.category != .trash }.map(\.url))
        recountAll()
        if focused == nil || !results.contains(where: { $0.id == focused }) {
            focused = results.first?.id
        }
        refreshVisible()
    }

    // MARK: - Seleção

    func isSelected(_ entry: CleanupEntry) -> Bool { selection.contains(entry.url) }

    func toggle(_ entry: CleanupEntry) {
        guard entry.category != .trash else { return }
        let delta = selection.remove(entry.url) == nil ? 1 : -1
        if delta == 1 { selection.insert(entry.url) }
        selectedCount += delta
        selectedBytes += Int64(delta) * entry.size
        selectedPerCategory[entry.category, default: 0] += delta
    }

    /// Marca (ou desmarca) vários itens de uma vez. Se todos já estão marcados, desmarca.
    func toggle(_ urls: Set<URL>) {
        let entries = visibleEntries.filter { urls.contains($0.url) && $0.category != .trash }
        guard !entries.isEmpty else { return }
        setSelected(entries, !entries.allSatisfy { selection.contains($0.url) })
    }

    func setSelected(_ urls: Set<URL>, _ on: Bool) {
        setSelected(visibleEntries.filter { urls.contains($0.url) }, on)
    }

    func checkState(_ id: CleanupCategoryID) -> TriStateCheckbox.CheckState {
        guard let result = results.first(where: { $0.id == id }) else { return .off }
        let selected = selectedPerCategory[id] ?? 0
        if selected == 0 { return .off }
        return selected == result.entries.count ? .on : .mixed
    }

    func toggleCategory(_ id: CleanupCategoryID) {
        guard let result = results.first(where: { $0.id == id }), !result.isTrash else { return }
        setSelected(result.entries, checkState(id) != .on)
    }

    /// Volta à seleção sugerida (só o que é seguro limpar agora).
    func selectRecommended() {
        selection = Set(results.lazy.filter { !$0.isTrash }.flatMap(\.entries).filter(\.isRecommended).map(\.url))
        recountSelection()
    }

    func deselectAll() {
        selection = []
        recountSelection()
    }

    /// Marcados que são de apps abertos ou estão sendo gravados (para o aviso da confirmação).
    var selectedBusyCount: Int {
        results.lazy.filter { !$0.isTrash && $0.runningCount > 0 }.flatMap(\.entries)
            .filter { ($0.isAppRunning || $0.isActive) && self.selection.contains($0.url) }
            .count
    }

    private func setSelected(_ entries: [CleanupEntry], _ on: Bool) {
        for entry in entries where entry.category != .trash {
            if on { selection.insert(entry.url) } else { selection.remove(entry.url) }
        }
        recountSelection()
    }

    // MARK: - Depois da remoção

    /// Tira da lista o que saiu do lugar e refaz os totais. Se foi para a Lixeira, relê a Lixeira.
    func didRemove(_ report: RemovalReport) {
        let removed = report.removedSet
        guard !removed.isEmpty else { return }
        drop { removed.contains($0.url) }
        if report.mode == .trash { refreshTrash() }
    }

    /// "Ignorar sempre esta pasta": some da lista junto com o que estiver dentro dela.
    func ignore(_ url: URL) {
        let path = url.standardizedFileURL.path
        drop { entry in
            let entryPath = entry.url.standardizedFileURL.path
            return entryPath == path || entryPath.hasPrefix(path + "/")
        }
    }

    private func drop(where shouldDrop: (CleanupEntry) -> Bool) {
        var changed = false
        for index in results.indices {
            let before = results[index].entries.count
            results[index].entries.removeAll(where: shouldDrop)
            if results[index].entries.count != before {
                results[index].recount()
                changed = true
            }
        }
        guard changed else { return }
        results.removeAll { $0.entries.isEmpty }
        let remaining = Set(results.lazy.flatMap(\.entries).map(\.url))
        selection.formIntersection(remaining)
        recountAll()
        if focused == nil || !results.contains(where: { $0.id == focused }) {
            focused = results.first?.id
        }
        refreshVisible()
    }

    /// Itens mandados para a Lixeira agora fazem parte dela.
    private func refreshTrash() {
        trashTask?.cancel()
        let options = CleanupScanner.Options(hasFullDiskAccess: FullDiskAccess.isGranted, categories: [.trash])
        trashTask = Task { [weak self] in
            let result = await CleanupScanner().scan(options)
            guard !Task.isCancelled, !result.wasCancelled, let self, !self.isScanning, self.lastScan != nil else { return }
            self.replaceTrash(result.entries)
        }
    }

    private func replaceTrash(_ entries: [CleanupEntry]) {
        results.removeAll { $0.isTrash }
        if !entries.isEmpty {
            let trash = CategoryResult(category: CleanupCatalog.category(.trash), entries: entries.sorted(by: Self.bySize))
            // A Lixeira é sempre a última categoria.
            results.append(trash)
        }
        recountAll()
        if focused == nil || !results.contains(where: { $0.id == focused }) {
            focused = results.first?.id
        }
        refreshVisible()
    }

    // MARK: - Totais

    private func recountAll() {
        totalBytes = 0
        totalCount = 0
        trashBytes = 0
        trashCount = 0
        for result in results {
            if result.isTrash {
                trashBytes += result.bytes
                trashCount += result.entries.count
            } else {
                totalBytes += result.bytes
                totalCount += result.entries.count
            }
        }
        recountSelection()
    }

    private func recountSelection() {
        var count = 0
        var bytes: Int64 = 0
        var perCategory: [CleanupCategoryID: Int] = [:]
        for result in results where !result.isTrash {
            var inCategory = 0
            for entry in result.entries where selection.contains(entry.url) {
                inCategory += 1
                bytes += entry.size
            }
            count += inCategory
            perCategory[result.id] = inCategory
        }
        selectedCount = count
        selectedBytes = bytes
        selectedPerCategory = perCategory
    }

    private func refreshVisible() {
        guard let focused, let result = results.first(where: { $0.id == focused }) else {
            visibleEntries = []
            return
        }
        switch sortOrder {
        case .size:
            visibleEntries = result.entries
        case .name:
            visibleEntries = result.entries.sorted {
                let order = $0.label.localizedStandardCompare($1.label)
                return order == .orderedSame ? Self.bySize($0, $1) : order == .orderedAscending
            }
        }
    }

    private static func bySize(_ a: CleanupEntry, _ b: CleanupEntry) -> Bool {
        a.size != b.size ? a.size > b.size : a.url.path < b.url.path
    }
}

typealias CleanupCategoryResult = CleanupModel.CategoryResult
