import CleanerCore
import SwiftUI

/// Onde a varredura procura.
enum LargeOldRoot: Hashable {
    case home
    case folder(URL)
    case volume(LargeOldVolume)

    var url: URL {
        switch self {
        case .home: Paths.home
        case .folder(let url): url
        case .volume(let volume): volume.url
        }
    }

    var title: String {
        switch self {
        case .home: "Pasta pessoal"
        case .folder(let url): FileManager.default.displayName(atPath: url.path)
        case .volume(let volume): volume.name
        }
    }

    /// "na sua pasta pessoal", "em “Projetos”".
    var inPhrase: String {
        self == .home ? "na sua pasta pessoal" : "em “\(title)”"
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .folder: "folder"
        case .volume(let volume): volume.isNetwork ? "network" : "externaldrive"
        }
    }
}

@Observable
@MainActor
final class LargeOldModel: ScanningFeature {
    // MARK: Varredura

    private(set) var isScanning = false
    private(set) var progress = LargeOldProgress()
    private(set) var root: LargeOldRoot = .home
    /// Raiz dos resultados na tela (nil = ainda não escaneou).
    private(set) var scannedRoot: LargeOldRoot?
    private(set) var volumes: [LargeOldVolume] = []
    /// Motivo de uma varredura recusada (a tela mostra num alerta e limpa).
    var issue: String?

    // MARK: Filtros

    var threshold: LargeOldSizeThreshold = .default {
        didSet { if threshold != oldValue { thresholdChanged() } }
    }
    var age: LargeOldAge = .any {
        didSet { if age != oldValue { refilter() } }
    }
    /// Vazio = todos os tipos.
    var kinds: Set<LargeOldKind> = [] {
        didSet {
            // Todos marcados = nenhum filtro (atribuir aqui dentro não dispara o didSet de novo).
            if kinds.count == LargeOldKind.allCases.count { kinds = [] }
            if kinds != oldValue { refilter() }
        }
    }
    var searchText = "" {
        didSet { if searchText != oldValue { refilter() } }
    }
    var sortOrder: [KeyPathComparator<LargeOldFile>] = [KeyPathComparator(\.size, order: .reverse)] {
        didSet { if sortOrder != oldValue { resort() } }
    }

    var hasActiveFilters: Bool { age != .any || !kinds.isEmpty || !searchText.isEmpty }

    // MARK: Resultados (derivados ficam em cache: a tabela pode ter dezenas de milhares de linhas)

    /// Tudo o que a varredura achou, já na ordem da tabela.
    private(set) var files: [LargeOldFile] = []
    private(set) var visible: [LargeOldFile] = []
    private(set) var visibleBytes: Int64 = 0
    /// Por tipo, respeitando tamanho e idade (não o tipo escolhido).
    private(set) var kindTotals: [LargeOldKind: LargeOldKindTotal] = [:]
    private(set) var checked: Set<URL> = []
    private(set) var checkedBytes: Int64 = 0
    private(set) var visibleCheckedCount = 0
    /// Linhas destacadas na tabela (Quick Look, menu de contexto). Não é a marcação para remover.
    var tableSelection: Set<URL> = []

    /// Resultados no tamanho e idade escolhidos (sem tipo nem busca): é o número do selo.
    private(set) var resultCount = 0

    private(set) var summary: ScanSummary?

    var badge: String? {
        guard scannedRoot != nil, resultCount > 0 else { return nil }
        return resultCount.formatted()
    }

    var visibleCheckState: TriStateCheckbox.CheckState {
        if visibleCheckedCount == 0 { return .off }
        return visibleCheckedCount == visible.count ? .on : .mixed
    }

    /// Marcados que os filtros atuais escondem (também vão para a remoção).
    var hiddenCheckedCount: Int { checked.count - visibleCheckedCount }

    @ObservationIgnored private var scanTask: Task<LargeOldScanOutcome, Never>?
    @ObservationIgnored private var generation = 0
    /// Andamento final da varredura que está na tela (volta a valer se a próxima for cancelada).
    @ObservationIgnored private var resultProgress = LargeOldProgress()
    @ObservationIgnored private var scannedMinSize: Int64 = .max
    @ObservationIgnored private var scanningMinSize: Int64 = .max
    @ObservationIgnored private var sizes: [URL: Int64] = [:]

    init() {}

    // MARK: - Varredura

    /// Painel: varre a pasta pessoal com os filtros atuais e espera terminar.
    func scan() async {
        root = .home
        await performScan()
    }

    /// Botões da tela (não esperam o fim).
    func startScan() {
        Task { await performScan() }
    }

    /// Troca a raiz e já varre. Se a pasta não servir, o motivo chega em `issue`.
    func choose(_ newRoot: LargeOldRoot) {
        // A pasta pessoal escolhida no painel de pastas é a mesma raiz do Painel (e alimenta o resumo).
        if case .folder(let url) = newRoot, url.standardizedFileURL.path == Paths.home.standardizedFileURL.path {
            root = .home
        } else {
            root = newRoot
        }
        startScan()
    }

    func cancel() {
        scanTask?.cancel()
    }

    func refreshVolumes() async {
        let found = await Task.detached(priority: .utility) { LargeOldScanner.scannableVolumes() }.value
        if found != volumes { volumes = found }
    }

    private func performScan() async {
        scanTask?.cancel()
        generation += 1
        let gen = generation
        // O Painel conta a partir de 50 MB: nunca varre acima disso, o filtro de tamanho é aplicado depois.
        let minSize = min(threshold.bytes, LargeOldFilter.dashboard.minSize)
        let scanRoot = root
        let options = LargeOldScanOptions(root: scanRoot.url, minSize: minSize)
        scanningMinSize = minSize
        progress = LargeOldProgress()
        isScanning = true

        let task = Task.detached(priority: .userInitiated) { () -> LargeOldScanOutcome in
            // Validar a raiz toca o disco (pode ser de rede): fora da main.
            if let problem = LargeOldScanner.rootProblem(options.root, exclusions: options.exclusions) {
                return LargeOldScanOutcome(problem: problem)
            }
            let last = LargeOldProgressBox()
            let files = await LargeOldScanner.scan(options) { update in
                last.keep(update)
                Task { @MainActor in self.receive(update, generation: gen) }
            }
            return LargeOldScanOutcome(files: files, progress: last.value)
        }
        scanTask = task
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }

        guard gen == generation else { return }   // outra varredura tomou o lugar
        scanTask = nil
        isScanning = false
        if let problem = outcome.problem {
            issue = problem
            progress = resultProgress
            root = scannedRoot ?? .home
        } else if task.isCancelled {
            progress = resultProgress
            root = scannedRoot ?? root
        } else {
            apply(outcome.files, progress: outcome.progress, root: scanRoot, minSize: minSize)
        }
    }

    private func receive(_ update: LargeOldProgress, generation gen: Int) {
        // Leitores em paralelo podem entregar fora de ordem; depois do fim vale o número final.
        guard gen == generation, isScanning, update.filesVisited >= progress.filesVisited else { return }
        progress = update
    }

    private func apply(_ found: [LargeOldFile], progress final: LargeOldProgress, root scanRoot: LargeOldRoot, minSize: Int64) {
        if scannedRoot != scanRoot {
            checked = []
            tableSelection = []
        }
        scannedRoot = scanRoot
        scannedMinSize = minSize
        progress = final
        resultProgress = final
        files = found.sorted(using: sortOrder)
        sizes = Dictionary(found.map { ($0.url, $0.size) }, uniquingKeysWith: { first, _ in first })
        checked = checked.filter { sizes[$0] != nil }
        tableSelection = tableSelection.filter { sizes[$0] != nil }
        refilter()
        // Tamanhos podem ter mudado e marcados podem ter sumido: soma de novo.
        recountChecked()
        if scanRoot == .home { summary = Self.makeSummary(files) }
    }

    private func thresholdChanged() {
        // Abaixo do que já foi varrido, falta gente na lista: varre de novo.
        if isScanning {
            if threshold.bytes < scanningMinSize { startScan() }
        } else if scannedRoot != nil, threshold.bytes < scannedMinSize {
            startScan()
        } else {
            refilter()
        }
    }

    static func makeSummary(_ files: [LargeOldFile]) -> ScanSummary {
        let old = LargeOldFilter.dashboard.apply(to: files)
        return ScanSummary(title: "Arquivos grandes e antigos",
                           bytes: old.reduce(0) { $0 + $1.size },
                           count: old.count,
                           detail: "50 MB ou mais, sem abrir há 6 meses ou mais")
    }

    // MARK: - Filtros

    func toggleKind(_ kind: LargeOldKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    func clearFilters() {
        age = .any
        kinds = []
        searchText = ""
    }

    private func resort() {
        files.sort(using: sortOrder)
        refilter()
    }

    /// Filtra mantendo a ordem de `files` (a ordenação só roda quando a coluna muda).
    private func refilter() {
        let filter = LargeOldFilter(minSize: threshold.bytes, age: age, kinds: kinds)
        let cutoff = age.cutoff(from: Date())
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var totals: [LargeOldKind: LargeOldKindTotal] = [:]
        var list: [LargeOldFile] = []
        var bytes: Int64 = 0
        var count = 0
        for file in files where filter.matchesSizeAndAge(file, cutoff: cutoff) {
            count += 1
            totals[file.kind, default: LargeOldKindTotal()].count += 1
            totals[file.kind, default: LargeOldKindTotal()].bytes += file.size
            guard kinds.isEmpty || kinds.contains(file.kind) else { continue }
            guard query.isEmpty || file.name.localizedStandardContains(query) else { continue }
            list.append(file)
            bytes += file.size
        }
        kindTotals = totals
        resultCount = count
        visible = list
        visibleBytes = bytes
        recountVisibleChecked()
    }

    // MARK: - Marcação

    func isChecked(_ file: LargeOldFile) -> Bool { checked.contains(file.url) }

    func toggle(_ file: LargeOldFile) {
        if checked.remove(file.url) != nil {
            checkedBytes -= file.size
            visibleCheckedCount -= 1
        } else {
            checked.insert(file.url)
            checkedBytes += file.size
            visibleCheckedCount += 1
        }
    }

    func setChecked(_ urls: Set<URL>, _ on: Bool) {
        let known = urls.filter { sizes[$0] != nil }
        if on { checked.formUnion(known) } else { checked.subtract(known) }
        recountChecked()
    }

    func toggleAllVisible() {
        let urls = Set(visible.map(\.url))
        setChecked(urls, visibleCheckState != .on)
    }

    func removalItems() -> [RemovalItem] {
        files.filter { checked.contains($0.url) }.map { RemovalItem(url: $0.url, size: $0.size) }
    }

    private func recountChecked() {
        checkedBytes = checked.reduce(0) { $0 + (sizes[$1] ?? 0) }
        recountVisibleChecked()
    }

    private func recountVisibleChecked() {
        visibleCheckedCount = checked.isEmpty ? 0 : visible.reduce(0) { $0 + (checked.contains($1.url) ? 1 : 0) }
    }

    // MARK: - Depois da remoção

    func didRemove(_ report: RemovalReport) {
        drop(report.removedSet)
    }

    /// Ignora sempre (Ajustes ▸ Ignorar) e tira da lista o que estiver ali dentro.
    func ignore(_ url: URL) {
        Exclusions.add(url)
        let path = url.standardizedFileURL.path
        drop(Set(files.lazy.map(\.url).filter { $0.path == path || $0.path.hasPrefix(path + "/") }))
    }

    private func drop(_ gone: Set<URL>) {
        guard !gone.isEmpty else { return }
        files.removeAll { gone.contains($0.url) }
        for url in gone { sizes[url] = nil }
        checked.subtract(gone)
        tableSelection.subtract(gone)
        checkedBytes = checked.reduce(0) { $0 + (sizes[$1] ?? 0) }
        refilter()
        if scannedRoot == .home { summary = Self.makeSummary(files) }
    }
}

private struct LargeOldScanOutcome: Sendable {
    var problem: String?
    var files: [LargeOldFile] = []
    var progress = LargeOldProgress()
}

/// Último andamento entregue pelos leitores (o relatório final sai antes de a varredura voltar).
private final class LargeOldProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last = LargeOldProgress()

    func keep(_ progress: LargeOldProgress) { lock.withLock { last = progress } }
    var value: LargeOldProgress { lock.withLock { last } }
}
