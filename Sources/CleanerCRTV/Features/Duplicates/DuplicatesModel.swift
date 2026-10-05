import CleanerCore
import SwiftUI

/// Ordem da lista de grupos.
enum DuplicateSortOrder: String, CaseIterable, Identifiable {
    case wasted, size, copies, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wasted: "Maior desperdício"
        case .size: "Maior arquivo"
        case .copies: "Mais cópias"
        case .name: "Nome"
        }
    }
}

/// Números da última varredura concluída.
struct DuplicateScanStats: Equatable {
    var filesConsidered: Int
    var skippedCloud: Int
    var skippedUnreadable: Int
    var minSize: DuplicateMinSize
    var date: Date
}

@Observable
@MainActor
final class DuplicatesModel: ScanningFeature {
    // MARK: - Ajustes (persistidos)

    private(set) var roots: [URL] = DuplicateRoots.load()
    var minSize: DuplicateMinSize = .load() {
        didSet {
            guard minSize != oldValue else { return }
            minSize.save()
            if stats != nil { settingsChanged = true }
        }
    }

    // MARK: - Varredura

    private(set) var isScanning = false
    private(set) var progress = DuplicateProgressSnapshot()
    /// nil até a primeira varredura terminar.
    private(set) var stats: DuplicateScanStats?
    private(set) var groups: [DuplicateGroup] = []
    /// Pastas ou tamanho mínimo mudaram depois da última varredura.
    private(set) var settingsChanged = false

    // MARK: - Lista

    var sortOrder: DuplicateSortOrder = .wasted { didSet { if sortOrder != oldValue { rebuildSorted() } } }
    var kindFilter: DuplicateKind? { didSet { if kindFilter != oldValue { rebuildVisible() } } }
    var searchText = "" { didSet { if searchText != oldValue { rebuildVisible() } } }
    private(set) var visibleGroups: [DuplicateGroup] = []
    private(set) var availableKinds: [DuplicateKind] = []
    var focusedGroupID: String?

    // MARK: - Seleção

    private(set) var selection: Set<URL> = []
    private(set) var selectedCount = 0
    /// Estimativa do que volta ao disco (clones e links físicos liberam pouco ou nada).
    private(set) var selectedBytes: Int64 = 0
    private(set) var isPreparingRemoval = false
    /// Aviso curto no detalhe (ex.: tentativa de marcar a última cópia).
    private(set) var hint: String?

    // MARK: - Totais

    /// Desperdício recuperável (grupos de clones APFS ficam de fora).
    private(set) var totalReclaimable: Int64 = 0
    /// Cópias além da primeira, somando todos os grupos.
    private(set) var extraCopies = 0

    /// Observado: as caixas de cada linha da lista leem daqui.
    private var selectionByGroup: [String: (count: Int, bytes: Int64)] = [:]
    @ObservationIgnored private var sortedGroups: [DuplicateGroup] = []
    @ObservationIgnored private var groupIndex: [String: Int] = [:]
    @ObservationIgnored private var scanTask: Task<DuplicateScanResult?, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?

    init() {}

    // MARK: - ScanningFeature

    var badge: String? {
        guard stats != nil, totalReclaimable > 0 else { return nil }
        return totalReclaimable.formattedBytes
    }

    var summary: ScanSummary? {
        guard stats != nil else { return nil }
        let detail: String = groups.isEmpty
            ? "Nenhum arquivo repetido"
            : "\(extraCopies) \(extraCopies == 1 ? "cópia extra" : "cópias extras") em \(groups.count) \(groups.count == 1 ? "grupo" : "grupos")"
        return ScanSummary(title: "Duplicados", bytes: totalReclaimable, count: groups.count, detail: detail)
    }

    var hasResults: Bool { stats != nil }

    func scan() async {
        if let running = scanTask {
            _ = await running.value
            return
        }
        let options = DuplicateScanOptions(roots: roots, minSize: minSize.bytes)
        let scannedMinSize = minSize
        let tracker = DuplicateProgress()
        progress = DuplicateProgressSnapshot()
        isScanning = true
        clearHint()

        let task = Task.detached(priority: .userInitiated) {
            await DuplicateScanner.scan(options, progress: tracker)
        }
        scanTask = task
        // A varredura escreve o progresso sem parar; a interface lê ~8 vezes por segundo.
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(125))
                guard !Task.isCancelled else { break }
                self?.progress = tracker.snapshot
            }
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        poller.cancel()
        scanTask = nil
        isScanning = false
        // Cancelada: o resultado anterior (se houver) continua valendo.
        guard let result else { return }
        apply(result, minSize: scannedMinSize)
    }

    func cancel() {
        scanTask?.cancel()
    }

    // MARK: - Pastas

    /// Devolve os motivos das pastas recusadas.
    @discardableResult
    func addRoots(_ urls: [URL]) -> [String] {
        var problems: [String] = []
        var next = roots
        for url in urls {
            let step = DuplicateRoots.adding(url, to: next)
            if let problem = step.problem { problems.append(problem) } else { next = step.roots }
        }
        setRoots(next)
        return problems
    }

    func removeRoot(_ url: URL) {
        setRoots(roots.filter { $0 != url })
    }

    func restoreDefaultRoots() {
        setRoots(DuplicateRoots.defaults)
    }

    var rootsAreDefault: Bool {
        roots.map(\.standardizedFileURL.path) == DuplicateRoots.defaults.map(\.standardizedFileURL.path)
    }

    private func setRoots(_ next: [URL]) {
        guard next != roots else { return }
        roots = next
        DuplicateRoots.save(next)
        if stats != nil { settingsChanged = true }
    }

    // MARK: - Consultas para a interface

    var focusedGroup: DuplicateGroup? {
        guard let id = focusedGroupID, let index = groupIndex[id] else { return nil }
        return groups[index]
    }

    func isSelected(_ file: DuplicateFile) -> Bool { selection.contains(file.url) }

    func checkState(_ group: DuplicateGroup) -> TriStateCheckbox.CheckState {
        let count = selectionByGroup[group.id]?.count ?? 0
        if count == 0 { return .off }
        return count == group.files.count - 1 ? .on : .mixed
    }

    func selectedCount(in group: DuplicateGroup) -> Int { selectionByGroup[group.id]?.count ?? 0 }

    /// A lista está filtrada (as ações em massa valem só para o que aparece).
    var isFiltered: Bool { kindFilter != nil || !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Seleção

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        let step = DuplicateSelector.toggle(file.url, in: group, selection: selection)
        if step.refused {
            showHint("Pelo menos uma cópia de cada arquivo fica no lugar.")
            return
        }
        selection = step.selection
        refreshSelection(of: group)
    }

    func toggleGroup(_ group: DuplicateGroup, rule: DuplicateKeepRule = .oldest) {
        selection = DuplicateSelector.toggleGroup(group, rule: rule, selection: selection)
        refreshSelection(of: group)
    }

    func keepOnly(_ file: DuplicateFile, in group: DuplicateGroup) {
        selection = DuplicateSelector.keepOnly(file.url, in: group, selection: selection)
        refreshSelection(of: group)
    }

    /// Aplica a regra aos grupos visíveis. Grupos de clones APFS ficam desmarcados.
    func autoSelect(_ rule: DuplicateKeepRule) {
        let targets = visibleGroups
        var next = selection
        for group in targets { next.subtract(group.files.map(\.url)) }
        next.formUnion(DuplicateSelector.autoSelect(targets, rule: rule))
        selection = next
        recomputeSelection()
        let clones = targets.lazy.filter(\.isCloneGroup).count
        if clones > 0 {
            showHint("\(clones) \(clones == 1 ? "grupo de clones APFS ficou desmarcado" : "grupos de clones APFS ficaram desmarcados"): remover não libera espaço.")
        } else {
            clearHint()
        }
    }

    func deselectAll() {
        if isFiltered {
            var next = selection
            for group in visibleGroups { next.subtract(group.files.map(\.url)) }
            selection = next
        } else {
            selection = []
        }
        recomputeSelection()
        clearHint()
    }

    // MARK: - Remoção

    /// Confere o disco fora da main logo antes de pedir a confirmação.
    func prepareRemoval() async -> DuplicateRemovalPlan {
        let chosen = groups.filter { (selectionByGroup[$0.id]?.count ?? 0) > 0 }
        let selection = selection
        isPreparingRemoval = true
        defer { isPreparingRemoval = false }
        return await Task.detached(priority: .userInitiated) {
            DuplicateSelector.removalPlan(groups: chosen, selection: selection)
        }.value
    }

    /// Tira da lista o que saiu; grupos com menos de 2 cópias somem.
    func applyRemoval(_ report: RemovalReport) {
        dropFiles(report.removedSet)
    }

    /// "Ignorar sempre esta pasta": grava a exclusão e tira os arquivos dela da lista.
    func ignoreFolder(_ folder: URL) {
        Exclusions.add(folder)
        let prefix = folder.standardizedFileURL.path + "/"
        let urls = groups.flatMap { $0.files.lazy.map(\.url).filter { $0.path.hasPrefix(prefix) } }
        dropFiles(Set(urls))
    }

    private func dropFiles(_ removed: Set<URL>) {
        guard !removed.isEmpty else { return }
        let previousOrder = visibleGroups.map(\.id)
        let focused = focusedGroupID
        groups = groups.compactMap { group in
            group.files.contains(where: { removed.contains($0.url) }) ? group.removing(removed) : group
        }
        let alive = Set(groups.lazy.flatMap { $0.files.map(\.url) })
        selection = selection.subtracting(removed).intersection(alive)
        rebuildAll()
        // Se o grupo em foco sumiu, o foco vai para o vizinho que sobrou.
        if let focused, groupIndex[focused] == nil {
            let start = previousOrder.firstIndex(of: focused) ?? 0
            let visibleIDs = Set(visibleGroups.map(\.id))
            focusedGroupID = previousOrder[start...].first(where: visibleIDs.contains)
                ?? previousOrder[..<start].last(where: visibleIDs.contains)
        }
    }

    // MARK: - Interno

    private func apply(_ result: DuplicateScanResult, minSize: DuplicateMinSize) {
        stats = DuplicateScanStats(filesConsidered: result.filesConsidered, skippedCloud: result.skippedCloud,
                                   skippedUnreadable: result.skippedUnreadable, minSize: minSize, date: Date())
        groups = result.groups
        selection = []
        settingsChanged = false
        rebuildAll()
        focusedGroupID = visibleGroups.first?.id
    }

    private func rebuildAll() {
        groupIndex = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        totalReclaimable = groups.reduce(0) { $0 + $1.reclaimable }
        extraCopies = groups.reduce(0) { $0 + $1.files.count - 1 }
        let kinds = Set(groups.map(\.kind))
        availableKinds = DuplicateKind.allCases.filter(kinds.contains)
        if let kindFilter, !kinds.contains(kindFilter) { self.kindFilter = nil }
        recomputeSelection()
        rebuildSorted()
    }

    private func rebuildSorted() {
        switch sortOrder {
        case .wasted:
            sortedGroups = groups.sorted { (a: DuplicateGroup, b: DuplicateGroup) -> Bool in
                if a.reclaimable != b.reclaimable { return a.reclaimable > b.reclaimable }
                if a.wasted != b.wasted { return a.wasted > b.wasted }
                return a.id < b.id
            }
        case .size:
            sortedGroups = groups.sorted { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }
        case .copies:
            sortedGroups = groups.sorted {
                $0.files.count != $1.files.count ? $0.files.count > $1.files.count : $0.wasted > $1.wasted
            }
        case .name:
            sortedGroups = groups.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
        rebuildVisible()
    }

    private func rebuildVisible() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let kind = kindFilter
        if query.isEmpty, kind == nil {
            visibleGroups = sortedGroups
        } else {
            visibleGroups = sortedGroups.filter { group in
                (kind == nil || group.kind == kind)
                    && (query.isEmpty || group.files.contains { $0.name.localizedStandardContains(query) })
            }
        }
    }

    /// Recalcula a seleção de todos os grupos (ações em massa).
    private func recomputeSelection() {
        // Monta fora da propriedade observada: uma notificação só, não uma por grupo.
        var byGroup: [String: (count: Int, bytes: Int64)] = [:]
        var count = 0
        var bytes: Int64 = 0
        if !selection.isEmpty {
            for group in groups {
                let entry = selectionEntry(group)
                guard entry.count > 0 else { continue }
                byGroup[group.id] = entry
                count += entry.count
                bytes += entry.bytes
            }
        }
        selectionByGroup = byGroup
        selectedCount = count
        selectedBytes = bytes
    }

    /// Atualiza só um grupo (clique numa caixa).
    private func refreshSelection(of group: DuplicateGroup) {
        let old = selectionByGroup[group.id] ?? (0, 0)
        let new = selectionEntry(group)
        selectionByGroup[group.id] = new.count > 0 ? new : nil
        selectedCount += new.count - old.count
        selectedBytes += new.bytes - old.bytes
    }

    private func selectionEntry(_ group: DuplicateGroup) -> (count: Int, bytes: Int64) {
        let chosen = Set(group.files.lazy.map(\.url).filter(selection.contains))
        guard !chosen.isEmpty else { return (0, 0) }
        let freed = group.freedBytes(removing: chosen).values.reduce(0, +)
        return (chosen.count, freed)
    }

    private func showHint(_ text: String) {
        hintTask?.cancel()
        hint = text
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }

    private func clearHint() {
        hintTask?.cancel()
        hint = nil
    }
}
