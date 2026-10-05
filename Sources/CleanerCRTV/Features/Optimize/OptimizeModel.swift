import CleanerCore
import SwiftUI

/// Otimização: agentes do launchd, itens de início e tarefas de manutenção.
@Observable
@MainActor
final class OptimizeModel: ScanningFeature {
    enum Section: String, CaseIterable, Identifiable {
        case agents, loginItems, maintenance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .agents: "Agentes de inicialização"
            case .loginItems: "Itens de início"
            case .maintenance: "Manutenção"
            }
        }
    }

    struct AgentGroup: Identifiable {
        let scope: OptimizeAgentScope
        let agents: [OptimizeLaunchAgent]
        var id: OptimizeAgentScope { scope }
    }

    enum LoginItemsState: Equatable {
        case idle, loading, loaded
        case failed(OptimizeLoginItemsError)
    }

    var section: Section = .agents

    // MARK: Agentes

    private(set) var agents: [OptimizeLaunchAgent] = [] { didSet { rebuildDerived() } }
    private(set) var hasScanned = false
    private(set) var isScanning = false
    private(set) var scanStatus: String?
    private(set) var busyAgents: Set<OptimizeLaunchAgent.ID> = []
    var searchText = "" { didSet { if searchText != oldValue { rebuildGroups() } } }
    var showSystem = true { didSet { if showSystem != oldValue { rebuildGroups() } } }

    // Derivados, recalculados só quando a lista ou o filtro mudam.
    private(set) var groups: [AgentGroup] = []
    private(set) var userAgentCount = 0
    private(set) var systemAgentCount = 0
    private(set) var runningCount = 0
    private(set) var brokenUserCount = 0
    private(set) var brokenRemovable: [OptimizeLaunchAgent] = []

    // MARK: Itens de início

    private(set) var loginItems: [OptimizeLoginItem] = []
    private(set) var loginItemsState: LoginItemsState = .idle
    private(set) var busyLoginItems: Set<OptimizeLoginItem.ID> = []

    // MARK: Manutenção

    let tasks = OptimizeMaintenanceCatalog.all
    private(set) var runningTasks: Set<String> = []
    /// Tarefas em andamento que dá para interromper (as que rodam sem senha).
    private(set) var stoppableTasks: Set<String> = []
    private(set) var outcomes: [String: OptimizeTaskOutcome] = [:]
    private(set) var lastRuns: [String: Date] = [:]

    @ObservationIgnored private var scanTask: Task<[OptimizeLaunchAgent], Never>?
    @ObservationIgnored private var taskHandles: [String: Task<Void, Never>] = [:]
    /// Agentes descarregados à espera da confirmação de remoção (nil = nenhuma remoção pendente).
    @ObservationIgnored private var pendingRemoval: [OptimizeLaunchAgent]?
    @ObservationIgnored private let log = OptimizeMaintenanceLog()

    init() {
        for task in tasks { lastRuns[task.id] = log.lastRun(task.id) }
    }

    // MARK: - ScanningFeature

    var badge: String? { brokenUserCount > 0 ? "\(brokenUserCount)" : nil }

    var summary: ScanSummary? {
        guard hasScanned else { return nil }
        return ScanSummary(
            title: "Inicialização",
            bytes: 0,
            count: userAgentCount + loginItems.count,
            detail: brokenUserCount > 0 ? "\(brokenUserCount) \(brokenUserCount == 1 ? "quebrado" : "quebrados")" : nil
        )
    }

    /// Relê o inventário de agentes (os itens de início dependem de permissão e ficam de fora).
    func scan() async {
        await loadAgents(showProgress: true)
    }

    func cancel() {
        scanTask?.cancel()
    }

    // MARK: - Agentes

    private func loadAgents(showProgress: Bool) async {
        if let scanTask {
            _ = await scanTask.value
            return
        }
        if showProgress {
            isScanning = true
            scanStatus = "Lendo os arquivos .plist…"
        }
        let (statuses, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached(priority: .userInitiated) { () -> [OptimizeLaunchAgent] in
            defer { continuation.finish() }
            return await OptimizeAgentScanner.inventory { continuation.yield($0) }
        }
        if showProgress {
            Task {
                for await status in statuses where isScanning { scanStatus = status }
            }
        }
        scanTask = task
        let result = await task.value
        scanTask = nil
        if showProgress {
            isScanning = false
            scanStatus = nil
        }
        guard !task.isCancelled else { return }
        agents = result
        hasScanned = true
    }

    /// Ativa ou desativa um agente do usuário. Devolve a mensagem de erro, se houver.
    func setEnabled(_ agent: OptimizeLaunchAgent, _ enabled: Bool) async -> String? {
        guard agent.isManageable, !busyAgents.contains(agent.id) else { return nil }
        busyAgents.insert(agent.id)
        // Otimista: o interruptor responde na hora; o launchd confirma logo depois.
        update(agent.id) { $0.disabledOverride = !enabled }
        let result = enabled ? await OptimizeLaunchctl.enable(agent) : await OptimizeLaunchctl.disable(agent)
        await loadAgents(showProgress: false)
        busyAgents.remove(agent.id)
        return result.message
    }

    /// Para os agentes no launchd e devolve os itens para a confirmação de remoção.
    /// Se a confirmação for cancelada, `removalSheetClosed()` volta a carregá-los.
    func prepareRemoval(_ targets: [OptimizeLaunchAgent]) async -> (items: [RemovalItem], stopped: Int) {
        let removable = targets.filter { $0.scope == .user && $0.isRemovable }
        guard !removable.isEmpty, pendingRemoval == nil else { return ([], 0) }
        busyAgents.formUnion(removable.map(\.id))
        let (items, stopped) = await Task.detached(priority: .userInitiated) { () -> ([RemovalItem], [OptimizeLaunchAgent]) in
            var stopped: [OptimizeLaunchAgent] = []
            for agent in removable where agent.isLoaded {
                if await OptimizeLaunchctl.bootoutIfLoaded(from: agent.url, label: agent.label).isOK { stopped.append(agent) }
            }
            let items = removable.map {
                RemovalItem(url: $0.url, size: FileSizer.allocatedSize(ofItem: $0.url), label: $0.displayName)
            }
            return (items, stopped)
        }.value
        busyAgents.subtract(removable.map(\.id))
        pendingRemoval = stopped
        return (items, stopped.count)
    }

    /// Conclusão da remoção: tira da lista o que saiu e recarrega o que ficou para trás.
    func finishRemoval(_ report: RemovalReport) {
        let removed = report.removedSet
        let stopped = pendingRemoval ?? []
        pendingRemoval = nil
        agents.removeAll { removed.contains($0.url) }
        let leftBehind = stopped.filter { !removed.contains($0.url) }
        if !leftBehind.isEmpty {
            Task { await restore(leftBehind) }
        }
    }

    /// A folha de confirmação fechou. Sem conclusão = cancelada: os agentes parados voltam.
    func removalSheetClosed() async {
        guard let stopped = pendingRemoval else { return }
        pendingRemoval = nil
        await restore(stopped)
    }

    private func restore(_ stopped: [OptimizeLaunchAgent]) async {
        guard !stopped.isEmpty else { return }
        for agent in stopped { await OptimizeLaunchctl.reload(agent) }
        await loadAgents(showProgress: false)
    }

    func agents(withIDs ids: Set<OptimizeLaunchAgent.ID>) -> [OptimizeLaunchAgent] {
        agents.filter { ids.contains($0.id) }
    }

    private func update(_ id: OptimizeLaunchAgent.ID, _ change: (inout OptimizeLaunchAgent) -> Void) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        change(&agents[index])
    }

    private func rebuildDerived() {
        let user = agents.filter { $0.scope == .user }
        userAgentCount = user.count
        systemAgentCount = agents.count - user.count
        runningCount = agents.reduce(0) { $0 + ($1.isRunning ? 1 : 0) }
        let broken = user.filter(\.isBroken)
        brokenUserCount = broken.count
        brokenRemovable = broken.filter(\.isRemovable)
        rebuildGroups()
    }

    private func rebuildGroups() {
        let visible = agents.filter { (showSystem || $0.scope == .user) && $0.matches(searchText) }
        groups = OptimizeAgentScope.allCases.compactMap { scope in
            let list = visible.filter { $0.scope == scope }
            return list.isEmpty ? nil : AgentGroup(scope: scope, agents: list)
        }
    }

    // MARK: - Itens de início

    /// Pede a lista ao Eventos do Sistema (na 1ª vez o macOS pergunta pela permissão de Automação).
    func loadLoginItems() async {
        guard loginItemsState != .loading else { return }
        loginItemsState = .loading
        switch await OptimizeLoginItems.list() {
        case .success(let items):
            loginItems = items
            loginItemsState = .loaded
        case .failure(let error):
            loginItemsState = .failed(error)
        }
    }

    /// Tira um app da lista de início. Devolve a mensagem de erro, se houver.
    func removeLoginItem(_ item: OptimizeLoginItem) async -> String? {
        guard !busyLoginItems.contains(item.id) else { return nil }
        busyLoginItems.insert(item.id)
        defer { busyLoginItems.remove(item.id) }
        switch await OptimizeLoginItems.remove(item) {
        case .success:
            loginItems.removeAll { $0.id == item.id }
            return nil
        case .failure(let error):
            return error.message
        }
    }

    // MARK: - Manutenção

    func run(_ task: OptimizeMaintenanceTask, asAdmin: Bool = false) {
        guard !runningTasks.contains(task.id) else { return }
        runningTasks.insert(task.id)
        let usesPassword = task.privilege == .admin || (asAdmin && task.privilege == .userThenAdmin)
        if !usesPassword { stoppableTasks.insert(task.id) }
        outcomes[task.id] = nil
        taskHandles[task.id] = Task { [weak self] in
            let outcome = await OptimizeMaintenanceRunner.run(task, asAdmin: asAdmin)
            self?.finish(task, outcome: outcome)
        }
    }

    func stop(_ task: OptimizeMaintenanceTask) {
        guard stoppableTasks.contains(task.id) else { return }
        taskHandles[task.id]?.cancel()
    }

    private func finish(_ task: OptimizeMaintenanceTask, outcome: OptimizeTaskOutcome) {
        runningTasks.remove(task.id)
        stoppableTasks.remove(task.id)
        taskHandles[task.id] = nil
        outcomes[task.id] = outcome
        log.record(task.id, outcome: outcome)
        if outcome.didRun { lastRuns[task.id] = outcome.date }
    }
}
