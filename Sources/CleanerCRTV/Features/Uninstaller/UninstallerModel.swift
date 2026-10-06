import AppKit
import CleanerCore
import SwiftUI

enum UninstallTab: String, CaseIterable, Identifiable {
    case apps, orphans
    var id: String { rawValue }
}

enum UninstallSort: String, CaseIterable, Identifiable {
    case name, size, lastUsed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Nome"
        case .size: "Tamanho"
        case .lastUsed: "Último uso"
        }
    }
}

enum UninstallAppFilter: String, CaseIterable, Identifiable {
    case all, unused, appStore, large
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Todos"
        case .unused: "Sem uso há 3+ meses"
        case .appStore: "App Store"
        case .large: "Grandes"
        }
    }
}

enum UninstallAction {
    /// Remove o app e os restos marcados.
    case uninstall
    /// Só os restos marcados: o app fica, como recém-instalado.
    case reset
}

/// Apps abertos que precisam fechar antes de seguir (confirmação na tela).
struct UninstallQuitRequest: Identifiable {
    let id = UUID()
    let action: UninstallAction
    let apps: [UninstallApp]
    let running: [UninstallApp]
}

@Observable
@MainActor
final class UninstallerModel: ScanningFeature {
    static let unusedInterval: TimeInterval = 90 * 86_400
    static let largeThreshold: Int64 = 1_000_000_000

    // MARK: Varredura

    private(set) var isScanning = false
    /// Procurando os apps (a tela mostra o progresso); depois a lista aparece e os tamanhos chegam aos poucos.
    private(set) var isDiscovering = false
    private(set) var isMeasuring = false
    private(set) var isSearchingOrphans = false
    private(set) var hasScanned = false
    private(set) var scanProgress: Double?
    private(set) var scanCounter: String?
    private(set) var measured = 0
    private(set) var toMeasure = 0
    private(set) var summary: ScanSummary?

    var badge: String? { orphanGroups.isEmpty ? nil : "\(orphanGroups.count)" }

    // MARK: Dados

    private(set) var apps: [UninstallApp] = [] {
        didSet { if !patchingSizes { refreshDerived() } }
    }
    private(set) var orphanGroups: [UninstallOrphanGroup] = []
    private(set) var runningIDs: Set<String> = []
    private(set) var leftovers: [URL: [UninstallLeftover]] = [:]
    private(set) var loadingLeftovers: Set<URL> = []
    /// Texto da operação em andamento (fechar app, medir…). nil = livre.
    private(set) var busyText: String?

    // MARK: Interface

    var tab: UninstallTab = .apps
    var searchText = "" { didSet { if searchText != oldValue { refreshDerived() } } }
    var sort: UninstallSort = .name { didSet { if sort != oldValue { refreshDerived() } } }
    var appFilter: UninstallAppFilter = .all { didSet { if appFilter != oldValue { refreshDerived() } } }
    var selection: Set<URL> = [] {
        didSet {
            guard selection != oldValue else { return }
            refreshSelected()
            _ = requestLeftovers(for: selectedApps)
        }
    }
    var checkedLeftovers: Set<URL> = []
    var checkedOrphans: Set<URL> = []
    var expandedOrphans: Set<String> = []
    var quitRequest: UninstallQuitRequest?

    /// Derivados guardados (a lista não recalcula nada pesado no `body`).
    private(set) var visibleApps: [UninstallApp] = []
    private(set) var selectedApps: [UninstallApp] = []
    private(set) var filterCounts: [UninstallAppFilter: Int] = [:]
    private(set) var totalAppBytes: Int64 = 0

    // MARK: Interno

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var orphanTask: Task<Void, Never>?
    /// Muda a cada busca de restos de apps removidos: resultado de busca antiga não sobrescreve o novo.
    @ObservationIgnored private var orphanToken = UUID()
    /// Busca de restos em andamento por app; o `token` diz qual pedido é o mais novo.
    @ObservationIgnored private var leftoverTasks: [URL: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var libraryIndex: UninstallLibraryIndex?
    @ObservationIgnored private var sizeCache: [URL: (stamp: String, size: Int64)] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var completedScan = false
    @ObservationIgnored private var patchingSizes = false

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
    }

    // MARK: - Varredura

    func scan() async {
        if let scanTask {
            await scanTask.value
            return
        }
        let task = Task { await self.performScan() }
        scanTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        scanTask = nil
    }

    func cancel() {
        scanTask?.cancel()
        stopOrphanSearch()
    }

    private func performScan() async {
        isScanning = true
        isDiscovering = true
        scanProgress = nil
        scanCounter = nil
        refreshRunning()
        stopOrphanSearch()
        let orphanGeneration = orphanToken
        defer {
            isScanning = false
            isDiscovering = false
            isMeasuring = false
        }

        let box = UninstallScanBox()
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                self?.drain(box)
            }
        }
        defer { poller.cancel() }

        let filter = UninstallFilter.live()
        let discovered = await UninstallInventory.discover(filter: filter) { done, total in box.progress(done, total) }
        guard !Task.isCancelled else { return }

        // Pacote igual ao da última varredura: o tamanho medido continua valendo.
        let found = discovered.map { app -> UninstallApp in
            var app = app
            if let cached = sizeCache[app.url], cached.stamp == app.stamp { app.size = cached.size }
            return app
        }
        // Restos: só os do que continua selecionado ficam (para manter as escolhas) e são relidos.
        let keep = selection.intersection(found.map(\.url))
        leftovers = leftovers.filter { keep.contains($0.key) }
        // Marcações de restos que saíram da lista não ficam valendo escondidas.
        checkedLeftovers.formIntersection(leftovers.values.flatMap { $0.map(\.url) })
        leftoverTasks.values.forEach { $0.task.cancel() }
        leftoverTasks = [:]
        loadingLeftovers = []
        libraryIndex = nil
        apps = found
        selection = keep
        requestLeftovers(for: selectedApps, force: true)

        hasScanned = true
        isDiscovering = false
        let pending = found.filter { $0.size == nil }.map(\.url)
        toMeasure = pending.count
        measured = 0
        isMeasuring = !pending.isEmpty

        let running = runningIDs
        async let sizes: Void = UninstallInventory.measureSizes(of: pending) { url, size in box.size(url, size) }
        async let orphans = Self.searchOrphans(installed: found, running: running)
        await sizes
        let (index, groups) = await orphans
        drain(box)
        guard !Task.isCancelled else { return }

        libraryIndex = index
        // Uma busca de restos disparada durante a varredura (após remover algo) é mais nova.
        if orphanToken == orphanGeneration { setOrphans(groups) }
        for app in apps { if let size = app.size { sizeCache[app.url] = (app.stamp, size) } }
        completedScan = true
        updateSummary()
    }

    @concurrent
    private static func searchOrphans(installed: [UninstallApp], running: Set<String>) async -> (UninstallLibraryIndex, [UninstallOrphanGroup]) {
        let index = await UninstallLibraryIndex.load()
        let groups = await UninstallOrphanFinder.find(installed: installed, runningIDs: running, index: index)
        return (index, groups)
    }

    /// Aplica o que a varredura juntou desde a última vez (≤ ~8 vezes por segundo).
    private func drain(_ box: UninstallScanBox) {
        let snapshot = box.take()
        if isDiscovering, let progress = snapshot.progress, progress.1 > 0 {
            scanProgress = Double(progress.0) / Double(progress.1)
            scanCounter = "\(progress.0) de \(progress.1) apps"
        }
        guard !snapshot.sizes.isEmpty else { return }
        measured += snapshot.sizes.count
        func patched(_ list: [UninstallApp]) -> [UninstallApp] {
            list.map { app in
                guard let size = snapshot.sizes[app.url] else { return app }
                var app = app
                app.size = size
                return app
            }
        }
        // Ordem e filtro não dependem do tamanho: só troca os números, sem reordenar a lista.
        if sort != .size, appFilter != .large {
            patchingSizes = true
            apps = patched(apps)
            patchingSizes = false
            visibleApps = patched(visibleApps)
            totalAppBytes = apps.reduce(0) { $0 + ($1.size ?? 0) }
            filterCounts[.large] = apps.reduce(0) { $0 + (($1.size ?? 0) >= Self.largeThreshold ? 1 : 0) }
            if selectedApps.contains(where: { snapshot.sizes[$0.url] != nil }) { refreshSelected() }
        } else {
            apps = patched(apps)
        }
    }

    private func updateSummary() {
        guard completedScan else { return }
        let cutoff = Date().addingTimeInterval(-Self.unusedInterval)
        let unused = apps.filter { $0.canUninstall && $0.isUnused(since: cutoff) }
        let orphanCount = orphanGroups.count
        summary = ScanSummary(
            title: "Apps sem uso",
            bytes: unused.reduce(0) { $0 + ($1.size ?? 0) },
            count: unused.count,
            detail: orphanCount > 0 ? "\(orphanCount) \(orphanCount == 1 ? "resto" : "restos") de apps removidos" : nil
        )
    }

    private func setOrphans(_ groups: [UninstallOrphanGroup]) {
        orphanGroups = groups
        let urls = Set(groups.flatMap { $0.items.map(\.url) })
        checkedOrphans.formIntersection(urls)
        expandedOrphans.formIntersection(groups.map(\.key))
    }

    // MARK: - Derivados

    private func refreshDerived() {
        let cutoff = Date().addingTimeInterval(-Self.unusedInterval)
        func passes(_ app: UninstallApp, _ filter: UninstallAppFilter) -> Bool {
            switch filter {
            case .all: true
            case .unused: app.canUninstall && app.isUnused(since: cutoff)
            case .appStore: app.isAppStore
            case .large: (app.size ?? 0) >= Self.largeThreshold
            }
        }
        var counts: [UninstallAppFilter: Int] = [:]
        for filter in UninstallAppFilter.allCases { counts[filter] = apps.reduce(0) { $0 + (passes($1, filter) ? 1 : 0) } }
        filterCounts = counts
        totalAppBytes = apps.reduce(0) { $0 + ($1.size ?? 0) }

        var list = apps.filter { passes($0, appFilter) }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        switch sort {
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            list.sort { ($0.size ?? -1, $1.name) > ($1.size ?? -1, $0.name) }
        case .lastUsed:
            // Mais esquecidos primeiro; sem registro no fim.
            list.sort { a, b in
                switch (a.lastUsed, b.lastUsed) {
                case let (x?, y?): x < y
                case (_?, nil): true
                case (nil, _?): false
                default: a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
        }
        visibleApps = list
        refreshSelected()
    }

    private func refreshSelected() {
        selectedApps = selection.isEmpty ? [] : apps.filter { selection.contains($0.url) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isRunning(_ app: UninstallApp) -> Bool {
        guard let id = app.bundleID else { return false }
        return runningIDs.contains(id)
    }

    private func refreshRunning() {
        let ids = RunningApps.bundleIdentifiers
        if ids != runningIDs { runningIDs = ids }
    }

    func toggle(_ app: UninstallApp) {
        if selection.contains(app.url) { selection.remove(app.url) } else { selection.insert(app.url) }
    }

    /// "Ignorar sempre esta pasta" num app da lista.
    func forget(_ app: UninstallApp) {
        apps.removeAll { $0.url == app.url }
        selection.remove(app.url)
        dropLeftovers(of: [app.url])
        updateSummary()
    }

    private func dropLeftovers(of appURLs: [URL]) {
        for url in appURLs {
            checkedLeftovers.subtract((leftovers[url] ?? []).map(\.url))
            leftovers[url] = nil
        }
    }

    func forgetLeftover(_ item: UninstallLeftover) {
        for key in leftovers.keys { leftovers[key]?.removeAll { $0.url == item.url } }
        checkedLeftovers.remove(item.url)
    }

    func forgetOrphan(_ item: UninstallLeftover) {
        dropOrphans([item.url])
    }

    // MARK: - Restos de um app

    /// Procura (em segundo plano) os restos dos apps que ainda não têm a lista pronta.
    @discardableResult
    func requestLeftovers(for targets: [UninstallApp], force: Bool = false) -> Task<Void, Never>? {
        let missing = targets.filter {
            $0.canUninstall && (force || (leftovers[$0.url] == nil && leftoverTasks[$0.url] == nil))
        }
        guard !missing.isEmpty else { return nil }
        let installed = apps
        let cachedIndex = libraryIndex
        let token = UUID()
        let task = Task { [weak self] in
            let index: UninstallLibraryIndex
            if let cachedIndex { index = cachedIndex } else { index = await UninstallLibraryIndex.load() }
            let found = await UninstallLeftoverFinder.find(for: missing, installed: installed, index: index)
            guard let self else { return }
            // Só vale para os apps em que este ainda é o pedido mais novo.
            let current = missing.map(\.url).filter { self.leftoverTasks[$0]?.token == token }
            for url in current {
                self.leftoverTasks[url] = nil
                self.loadingLeftovers.remove(url)
            }
            guard !Task.isCancelled else { return }
            if self.libraryIndex == nil { self.libraryIndex = index }
            self.applyLeftovers(found.filter { current.contains($0.key) })
        }
        for app in missing {
            leftoverTasks[app.url] = (token, task)
            loadingLeftovers.insert(app.url)
        }
        return task
    }

    /// Itens novos recebem a marcação padrão; os que já estavam na lista mantêm a escolha do usuário.
    private func applyLeftovers(_ found: [URL: [UninstallLeftover]]) {
        for (appURL, items) in found {
            let previous = Set((leftovers[appURL] ?? []).map(\.url))
            for item in items where !previous.contains(item.url) && item.isSelectedByDefault {
                checkedLeftovers.insert(item.url)
            }
            let current = Set(items.map(\.url))
            checkedLeftovers.subtract(previous.subtracting(current))
            leftovers[appURL] = items
        }
    }

    private func waitForLeftovers(_ targets: [UninstallApp]) async {
        requestLeftovers(for: targets)
        for app in targets {
            if let entry = leftoverTasks[app.url] { await entry.task.value }
        }
    }

    func checkedItems(of app: UninstallApp) -> [UninstallLeftover] {
        (leftovers[app.url] ?? []).filter { checkedLeftovers.contains($0.url) }
    }

    func setChecked(_ items: [UninstallLeftover], _ on: Bool) {
        let urls = items.map(\.url)
        if on { checkedLeftovers.formUnion(urls) } else { checkedLeftovers.subtract(urls) }
    }

    // MARK: - Desinstalar e redefinir

    /// Primeiro passo: se algum app estiver aberto, pede para fechar (a tela confirma).
    func begin(_ action: UninstallAction, apps targets: [UninstallApp], appModel: AppModel) async {
        let allowed = targets.filter(\.canUninstall)
        guard !allowed.isEmpty, busyText == nil else { return }
        busyText = "Procurando restos…"
        await waitForLeftovers(allowed)
        busyText = nil
        let running = allowed.filter { app in app.bundleID.map { RunningApps.isRunning(bundleID: $0) } ?? false }
        if running.isEmpty {
            await submit(action, apps: allowed, skipped: targets.count - allowed.count, closed: [], appModel: appModel)
        } else {
            quitRequest = UninstallQuitRequest(action: action, apps: allowed, running: running)
        }
    }

    /// Fecha os apps abertos (como ⌘Q), espera até ~5 s e segue para a confirmação de remoção.
    func quitAndContinue(_ request: UninstallQuitRequest, appModel: AppModel) async {
        quitRequest = nil
        let ids = request.running.compactMap(\.bundleID)
        busyText = request.running.count == 1 ? "Fechando \(request.running[0].name)…" : "Fechando \(request.running.count) apps…"
        ids.forEach { RunningApps.quit(bundleID: $0) }
        let deadline = ContinuousClock.now + .seconds(5)
        var alive = ids
        while !alive.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            alive = alive.filter { id in
                NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
            }
        }
        busyText = nil
        refreshRunning()
        if !alive.isEmpty {
            let names = request.running.filter { alive.contains($0.bundleID ?? "") }.map(\.name)
            appModel.alert = "\(UninstallFormat.list(names)) não \(names.count == 1 ? "fechou" : "fecharam"). "
                + "Salve o que estiver aberto, feche manualmente e tente de novo."
            return
        }
        // Ao fechar, o app grava preferências e estado salvo: a lista de restos é refeita.
        busyText = "Procurando restos…"
        libraryIndex = nil
        await requestLeftovers(for: request.running, force: true)?.value
        busyText = nil
        await submit(request.action, apps: request.apps, skipped: 0, closed: request.running.map(\.name), appModel: appModel)
    }

    private func submit(_ action: UninstallAction, apps targets: [UninstallApp], skipped: Int, closed: [String],
                        appModel: AppModel) async {
        var bundleSizes: [URL: Int64] = [:]
        if action == .uninstall {
            let unmeasured = targets.filter { $0.size == nil }.map(\.url)
            if !unmeasured.isEmpty {
                busyText = "Medindo…"
                bundleSizes = await Self.measure(unmeasured)
                busyText = nil
            }
        }

        var items: [RemovalItem] = []
        for app in targets {
            if action == .uninstall {
                items.append(RemovalItem(url: app.url, size: app.size ?? bundleSizes[app.url] ?? 0, label: app.name))
            }
            for item in checkedItems(of: app) {
                items.append(RemovalItem(url: item.url, size: item.size, label: "\(item.kind.label) · \(app.name)"))
            }
        }
        guard !items.isEmpty else { return }

        let title: String
        var notes: [String] = []
        switch action {
        case .uninstall:
            title = targets.count == 1 ? "Desinstalar \(targets[0].name)?" : "Desinstalar \(targets.count) apps?"
        case .reset:
            title = "Redefinir \(targets[0].name)?"
            notes.append("O app continua instalado e abre como na primeira vez.")
        }
        if !closed.isEmpty {
            notes.append("\(UninstallFormat.list(closed)) \(closed.count == 1 ? "foi fechado" : "foram fechados") para a remoção.")
        }
        if skipped > 0 {
            notes.append("\(skipped) \(skipped == 1 ? "app protegido ficou" : "apps protegidos ficaram") de fora.")
        }

        appModel.requestRemoval(items, source: Feature.uninstaller.title, title: title,
                                note: notes.isEmpty ? nil : notes.joined(separator: " ")) { [weak self] report in
            self?.didRemove(report, action: action)
        }
    }

    @concurrent
    private static func measure(_ urls: [URL]) async -> [URL: Int64] {
        var result: [URL: Int64] = [:]
        for url in urls { result[url] = FileSizer.allocatedSize(of: url) }
        return result
    }

    private func didRemove(_ report: RemovalReport, action: UninstallAction) {
        let removed = report.removedSet
        guard !removed.isEmpty else { return }
        if action == .uninstall {
            let gone = apps.filter { removed.contains($0.url) }.map(\.url)
            dropLeftovers(of: gone)
            for url in gone { sizeCache[url] = nil }
            selection.subtract(gone)
            apps.removeAll { removed.contains($0.url) }
        }
        for key in leftovers.keys { leftovers[key]?.removeAll { removed.contains($0.url) } }
        checkedLeftovers.subtract(removed)
        dropOrphans(removed)
        updateSummary()
        refreshAfterRemoval()
    }

    /// O disco mudou: relê a Biblioteca, os restos do que está selecionado e os restos de apps removidos.
    private func refreshAfterRemoval() {
        libraryIndex = nil
        _ = requestLeftovers(for: selectedApps, force: true)
        refreshOrphans()
    }

    func refreshOrphans() {
        stopOrphanSearch()
        let token = orphanToken
        isSearchingOrphans = true
        let installed = apps
        let running = runningIDs
        orphanTask = Task { [weak self] in
            let (index, groups) = await Self.searchOrphans(installed: installed, running: running)
            guard let self, self.orphanToken == token, !Task.isCancelled else { return }
            self.orphanTask = nil
            self.isSearchingOrphans = false
            if self.libraryIndex == nil { self.libraryIndex = index }
            self.setOrphans(groups)
            self.updateSummary()
        }
    }

    private func stopOrphanSearch() {
        orphanTask?.cancel()
        orphanTask = nil
        orphanToken = UUID()
        isSearchingOrphans = false
    }

    // MARK: - Restos de apps removidos

    var checkedOrphanItems: [UninstallLeftover] {
        orphanGroups.flatMap { $0.items.filter { checkedOrphans.contains($0.url) } }
    }

    func setOrphansChecked(_ items: [UninstallLeftover], _ on: Bool) {
        let urls = items.map(\.url)
        if on { checkedOrphans.formUnion(urls) } else { checkedOrphans.subtract(urls) }
    }

    func removeCheckedOrphans(appModel: AppModel) {
        var items: [RemovalItem] = []
        for group in orphanGroups {
            for item in group.items where checkedOrphans.contains(item.url) {
                items.append(RemovalItem(url: item.url, size: item.size, label: "\(item.kind.label) · \(group.key)"))
            }
        }
        guard !items.isEmpty else { return }
        appModel.requestRemoval(
            items, source: Feature.uninstaller.title,
            title: "Remover \(items.count) \(items.count == 1 ? "resto" : "restos") de apps removidos?",
            note: "São de apps que não estão mais instalados. Se algum for de uma ferramenta que você ainda usa, cancele e desmarque."
        ) { [weak self] report in
            guard let self else { return }
            self.dropOrphans(report.removedSet)
            self.updateSummary()
        }
    }

    private func dropOrphans(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        var groups = orphanGroups
        for i in groups.indices { groups[i].items.removeAll { urls.contains($0.url) } }
        groups.removeAll { $0.items.isEmpty }
        orphanGroups = groups
        checkedOrphans.subtract(urls)
    }
}

/// Ponte entre as tarefas da varredura e a main: elas escrevem aqui, a main lê a cada ~120 ms.
private final class UninstallScanBox: @unchecked Sendable {
    struct Snapshot {
        var progress: (Int, Int)?
        var sizes: [URL: Int64]
    }

    private let lock = NSLock()
    private var progressValue: (Int, Int)?
    private var sizes: [URL: Int64] = [:]

    func progress(_ done: Int, _ total: Int) {
        lock.withLock {
            if let current = progressValue, current.1 == total, current.0 > done { return }
            progressValue = (done, total)
        }
    }

    func size(_ url: URL, _ bytes: Int64) {
        lock.withLock { sizes[url] = bytes }
    }

    func take() -> Snapshot {
        lock.withLock {
            defer { sizes = [:] }
            return Snapshot(progress: progressValue, sizes: sizes)
        }
    }
}

/// Textos e formatos do módulo.
@MainActor
enum UninstallFormat {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    /// "há 3 meses", "ontem", "nunca registrado".
    static func lastUsed(_ date: Date?) -> String {
        guard let date else { return "nunca registrado" }
        if Date().timeIntervalSince(date) < 60 { return "agora" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// "A", "A e B", "A, B e C".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " e " + names[names.count - 1]
        }
    }

    static func displayPath(_ url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        let home = Paths.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }
}
