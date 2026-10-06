import AppKit
import CleanerCore
import SwiftUI

/// Quem está olhando o monitor. Sem ninguém, a amostragem para.
enum MonitorClient: Hashable {
    /// Texto/ícone na barra de menus.
    case menuBar
    /// Janelinha que abre pelo ícone da barra de menus.
    case panel
    /// Tela Monitor na janela principal.
    case screen
    /// `start()`/`stop()` (Painel e afins).
    case external
}

enum MonitorProcessScope: String, CaseIterable, Identifiable {
    case apps, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Apps"
        case .all: "Todos os processos"
        }
    }
}

enum MonitorRowID: Hashable {
    /// Pacote .app (o app somado aos ajudantes).
    case app(String)
    case process(Int32)
}

/// Linha da lista de processos, já com o nome do app quando o macOS o reconhece.
struct MonitorProcessRow: Identifiable, Equatable {
    let id: MonitorRowID
    var name: String
    /// Para apps, o processo principal (o que recebe "Encerrar").
    var pid: Int32
    var processCount: Int
    /// 1 = um núcleo inteiro.
    var cpu: Double
    var memory: Int64
    /// Pacote .app (ícone e conferência antes de encerrar); nil = processo solto.
    var bundlePath: String?
    var executablePath: String?
    var bundleIdentifier: String?
    var canTerminate: Bool
}

/// Séries dos gráficos, do mais antigo ao mais recente.
struct MonitorHistory: Equatable {
    var cpu: [Double] = []
    var memory: [Double] = []
    var netIn: [Double] = []
    var netOut: [Double] = []
    var diskRead: [Double] = []
    var diskWrite: [Double] = []
}

@Observable
@MainActor
final class MonitorModel {
    static let historyLength = 90

    let systemInfo = MonitorSampler.systemInfo

    // Leituras mais recentes (nil até haver dado)
    private(set) var cpu: MonitorCPU?
    private(set) var memory: MonitorMemory?
    private(set) var network: MonitorNetwork?
    private(set) var disk: MonitorDiskIO?
    private(set) var volume: VolumeUsage?
    private(set) var battery: MonitorBattery?
    private(set) var thermal: MonitorThermalState = .nominal
    private(set) var uptime: TimeInterval = 0
    private(set) var history = MonitorHistory()

    // Processos (só com o painel ou a tela Monitor à vista)
    private(set) var isDetailedVisible = false
    private(set) var hasProcesses = false
    /// false logo depois de abrir: a CPU por processo precisa de duas leituras.
    private(set) var processCPUValid = false
    private(set) var visibleRows: [MonitorProcessRow] = []
    /// Os 5 apps que mais usam memória (sem os do sistema), para o menu.
    private(set) var topApps: [MonitorProcessRow] = []
    private(set) var terminating: [Int32: Date] = [:]
    var scope: MonitorProcessScope = .apps { didSet { refreshVisibleRows() } }
    var query = "" { didSet { refreshVisibleRows() } }
    var sortOrder = [KeyPathComparator(\MonitorProcessRow.memory, order: .reverse)] { didSet { refreshVisibleRows() } }

    private(set) var isRunning = false

    @ObservationIgnored private let sampler = MonitorSampler()
    @ObservationIgnored private var clients: Set<MonitorClient> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var appRows: [MonitorProcessRow] = []
    @ObservationIgnored private var processRows: [MonitorProcessRow] = []
    @ObservationIgnored private var cpuRing = MonitorRingBuffer<Double>(capacity: MonitorModel.historyLength)
    @ObservationIgnored private var memoryRing = MonitorRingBuffer<Double>(capacity: MonitorModel.historyLength)
    @ObservationIgnored private var netInRing = MonitorRingBuffer<Double>(capacity: MonitorModel.historyLength)
    @ObservationIgnored private var netOutRing = MonitorRingBuffer<Double>(capacity: MonitorModel.historyLength)
    @ObservationIgnored private var readRing = MonitorRingBuffer<Double>(capacity: MonitorModel.historyLength)
    @ObservationIgnored private var writeRing = MonitorRingBuffer<Double>(capacity: MonitorModel.historyLength)

    init() {
        // O rótulo da barra de menus atualiza desde a abertura, mesmo antes de a view aparecer.
        if UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true {
            setActive(true, for: .menuBar)
        }
    }

    // MARK: - Ciclo de vida

    /// Mantém a amostragem ligada até `stop()` (idempotente). Não mexe nos outros clientes:
    /// a barra de menus continua atualizando depois de `stop()`.
    func start() { setActive(true, for: .external) }

    func stop() { setActive(false, for: .external) }

    func setActive(_ active: Bool, for client: MonitorClient) {
        let wasDetailed = isDetailedVisible
        if active { clients.insert(client) } else { clients.remove(client) }
        let detailed = clients.contains(.panel) || clients.contains(.screen)
        if detailed != isDetailedVisible { isDetailedVisible = detailed }

        if clients.isEmpty {
            loop?.cancel()
            loop = nil
            isRunning = false
        } else if loop == nil || (detailed && !wasDetailed) {
            // Recomeça na hora para a lista de processos aparecer sem esperar o próximo ciclo.
            restartLoop()
        }
    }

    private func restartLoop() {
        loop?.cancel()
        isRunning = true
        loop = Task { [weak self, sampler] in
            while !Task.isCancelled {
                guard let detailed = self?.isDetailedVisible else { return }
                let snapshot = await sampler.sample(detailed: detailed)
                guard !Task.isCancelled, let self else { return }
                self.apply(snapshot)
                // Primeira leitura (ou volta do repouso) só serve de base: a próxima vem logo.
                let quick = !snapshot.ratesValid || (detailed && !snapshot.processCPUValid)
                let interval: Duration = quick ? .seconds(1) : (detailed ? .seconds(2) : .seconds(3))
                try? await Task.sleep(for: interval, tolerance: quick ? .milliseconds(100) : .milliseconds(500))
            }
        }
    }

    // MARK: - Leituras

    private func apply(_ snapshot: MonitorSnapshot) {
        if let value = snapshot.cpu { cpu = value }
        if let value = snapshot.network { network = value }
        if let value = snapshot.disk { disk = value }
        if memory != snapshot.memory { memory = snapshot.memory }
        if let value = snapshot.volume, volume != value { volume = value }
        if battery != snapshot.battery { battery = snapshot.battery }
        if thermal != snapshot.thermal { thermal = snapshot.thermal }
        // O texto mostra minutos: atualizar a cada leitura só redesenharia à toa.
        if Int(snapshot.uptime / 60) != Int(uptime / 60) { uptime = snapshot.uptime }

        if snapshot.ratesValid {
            cpuRing.append(snapshot.cpu?.total ?? 0)
            memoryRing.append(snapshot.memory.usedFraction)
            netInRing.append(snapshot.network?.inPerSecond ?? 0)
            netOutRing.append(snapshot.network?.outPerSecond ?? 0)
            readRing.append(snapshot.disk?.readPerSecond ?? 0)
            writeRing.append(snapshot.disk?.writePerSecond ?? 0)
            history = MonitorHistory(cpu: cpuRing.elements, memory: memoryRing.elements,
                                     netIn: netInRing.elements, netOut: netOutRing.elements,
                                     diskRead: readRing.elements, diskWrite: writeRing.elements)
        }

        if let processes = snapshot.processes, let apps = snapshot.apps {
            buildRows(processes: processes, apps: apps, cpuValid: snapshot.processCPUValid)
        }
    }

    private func buildRows(processes: [MonitorProcess], apps: [MonitorAppGroup], cpuValid: Bool) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var running: [Int32: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { running[app.processIdentifier] = app }

        func allowed(_ app: NSRunningApplication?) -> Bool {
            guard let app else { return false }
            return MonitorTerminationPolicy.canTerminate(pid: app.processIdentifier, bundlePath: app.bundleURL?.path,
                                                         bundleIdentifier: app.bundleIdentifier,
                                                         isRegularApp: app.activationPolicy == .regular, ownPID: ownPID)
        }

        processRows = processes.map { process in
            let app = running[process.pid]
            return MonitorProcessRow(id: .process(process.pid), name: app?.localizedName ?? process.name, pid: process.pid,
                                     processCount: 1, cpu: process.cpu, memory: process.memory,
                                     bundlePath: app?.bundleURL?.path ?? process.appBundlePath,
                                     executablePath: process.path, bundleIdentifier: app?.bundleIdentifier,
                                     canTerminate: allowed(app))
        }

        appRows = apps.map { group in
            // O processo que o macOS trata como "o app" (com Dock), não um ajudante.
            let candidates = group.pids.compactMap { running[$0] }
            let app = candidates.first { $0.activationPolicy == .regular } ?? running[group.mainPID] ?? candidates.first
            return MonitorProcessRow(id: .app(group.bundlePath), name: app?.localizedName ?? group.name,
                                     pid: app?.processIdentifier ?? group.mainPID, processCount: group.pids.count,
                                     cpu: group.cpu, memory: group.memory,
                                     bundlePath: app?.bundleURL?.path ?? group.bundlePath,
                                     executablePath: app?.executableURL?.path, bundleIdentifier: app?.bundleIdentifier,
                                     canTerminate: allowed(app))
        }

        let top = Array(appRows.filter { !MonitorTerminationPolicy.isSystemBundle($0.bundlePath ?? "/System/Library/") }
            .sorted { $0.memory > $1.memory }
            .prefix(5))
        if top != topApps { topApps = top }
        if processCPUValid != cpuValid { processCPUValid = cpuValid }
        if !hasProcesses { hasProcesses = true }

        // Quem já saiu (ou recusou sair, ex.: documento sem salvar) deixa de aparecer como "encerrando".
        if !terminating.isEmpty {
            let alive = Set(processes.map(\.pid))
            let now = Date()
            let pending = terminating.filter { alive.contains($0.key) && now.timeIntervalSince($0.value) < 10 }
            if pending != terminating { terminating = pending }
        }
        refreshVisibleRows()
    }

    private func refreshVisibleRows() {
        var rows = scope == .apps ? appRows : processRows
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            rows = rows.filter { $0.name.localizedStandardContains(text) || String($0.pid) == text }
        }
        // PID desempata: sem isso, linhas com o mesmo valor trocam de lugar a cada leitura.
        rows.sort(using: sortOrder + [KeyPathComparator(\MonitorProcessRow.pid)])
        if rows != visibleRows { visibleRows = rows }
    }

    func row(_ id: MonitorRowID) -> MonitorProcessRow? {
        visibleRows.first { $0.id == id } ?? topApps.first { $0.id == id }
    }

    // MARK: - Encerrar

    func isTerminating(_ row: MonitorProcessRow) -> Bool { terminating[row.pid] != nil }

    /// Pede para o app fechar (como ⌘Q) ou força. Só apps comuns do usuário; confere de novo na hora,
    /// porque o PID pode ter sido reaproveitado por outro processo desde a última leitura.
    @discardableResult
    func terminate(_ row: MonitorProcessRow, force: Bool = false) -> Bool {
        guard row.canTerminate,
              let app = NSRunningApplication(processIdentifier: row.pid), !app.isTerminated,
              app.bundleIdentifier == row.bundleIdentifier, app.bundleURL?.path == row.bundlePath,
              MonitorTerminationPolicy.canTerminate(pid: app.processIdentifier, bundlePath: app.bundleURL?.path,
                                                    bundleIdentifier: app.bundleIdentifier,
                                                    isRegularApp: app.activationPolicy == .regular,
                                                    ownPID: ProcessInfo.processInfo.processIdentifier)
        else { return false }
        let sent = force ? app.forceTerminate() : app.terminate()
        if sent { terminating[row.pid] = Date() }
        return sent
    }
}
