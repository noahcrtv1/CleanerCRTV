import Foundation
import os

/// Varredura do "Lixo do sistema": acha os candidatos de cada regra (fase 1), mede em paralelo (fase 2).
/// Nunca remove nada: só propõe itens que o `SafetyGuard` deixaria remover e que não estão em pastas ignoradas.
public struct CleanupScanner: Sendable {
    public struct Options: Sendable {
        /// Raiz de todas as regras (injetável para testes).
        public var home: URL
        /// Apps abertos agora: os itens deles entram desmarcados.
        public var runningBundleIDs: Set<String>
        /// Nomes dos apps abertos, para caches com nome de app em vez de bundle ID (ex.: `Caches/Firefox`).
        public var runningAppNames: Set<String>
        public var hasFullDiskAccess: Bool
        public var now: Date
        public var categories: Set<CleanupCategoryID>
        /// nil = lê `Exclusions.paths` no início da varredura.
        public var excludedPaths: [String]?
        /// Última barreira antes de propor um item (padrão: `SafetyGuard`).
        public var isAllowed: @Sendable (URL) -> Bool
        public var resolver: CleanupAppResolver
        /// Itens medidos ao mesmo tempo.
        public var maxConcurrentSizing: Int

        public init(home: URL = Paths.home,
                    runningBundleIDs: Set<String> = [],
                    runningAppNames: Set<String> = [],
                    hasFullDiskAccess: Bool = true,
                    now: Date = Date(),
                    categories: Set<CleanupCategoryID> = Set(CleanupCategoryID.allCases),
                    excludedPaths: [String]? = nil,
                    isAllowed: @escaping @Sendable (URL) -> Bool = { SafetyGuard.check($0).isAllowed },
                    resolver: CleanupAppResolver = .shared,
                    maxConcurrentSizing: Int = 8) {
            self.home = home
            self.runningBundleIDs = runningBundleIDs
            self.runningAppNames = runningAppNames
            self.hasFullDiskAccess = hasFullDiskAccess
            self.now = now
            self.categories = categories
            self.excludedPaths = excludedPaths
            self.isAllowed = isAllowed
            self.resolver = resolver
            self.maxConcurrentSizing = maxConcurrentSizing
        }
    }

    public let catalog: [CleanupCategory]

    public init(catalog: [CleanupCategory] = CleanupCatalog.all) {
        self.catalog = catalog
    }

    /// `progress` é chamado de fora da main, no máximo ~10 vezes por segundo.
    /// Cancelar a tarefa interrompe as duas fases; o resultado vem com `wasCancelled`.
    public func scan(_ options: Options,
                     progress: @escaping @Sendable (CleanupScanProgress) -> Void = { _ in }) async -> CleanupScanResult {
        let flag = CleanupCancelFlag()
        let gate = CleanupProgressGate()
        return await withTaskCancellationHandler {
            await run(options, flag: flag, gate: gate, progress: progress)
        } onCancel: {
            flag.cancel()
        }
    }

    private func run(_ options: Options, flag: CleanupCancelFlag, gate: CleanupProgressGate,
                     progress: @escaping @Sendable (CleanupScanProgress) -> Void) async -> CleanupScanResult {
        let catalog = self.catalog
        let protected = CleanupCatalog.protectedPaths.map { options.home.appendingPathComponent($0).path }
        let excluded = ((options.excludedPaths ?? Exclusions.paths) + protected)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        // Fase 1: descoberta (rápida, só lista pastas).
        let (candidates, inaccessible) = await Self.offload { () -> ([CleanupCandidate], [String]) in
            let discovery = CleanupDiscovery(options: options, excluded: excluded, cancel: flag) { path in
                if gate.shouldEmit() {
                    progress(CleanupScanProgress(stage: .discovering, currentPath: path, measured: 0, total: 0,
                                                 foundCount: 0, foundBytes: 0))
                }
            }
            let found = discovery.run(catalog)
            return (found, discovery.inaccessible.sorted())
        }
        if flag.isCancelled { return CleanupScanResult(inaccessiblePaths: inaccessible, wasCancelled: true) }

        // Fase 2: tamanho de cada item, até `maxConcurrentSizing` de cada vez.
        let running = CleanupRunningSet(bundleIDs: options.runningBundleIDs, names: options.runningAppNames)
        var entries: [CleanupEntry] = []
        var measured = 0
        var bytes: Int64 = 0
        await withTaskGroup(of: CleanupEntry?.self) { group in
            var next = 0
            func enqueue() {
                let candidate = candidates[next]
                next += 1
                group.addTask {
                    await Self.offload { Self.makeEntry(candidate, options: options, running: running, flag: flag) }
                }
            }
            while next < min(max(1, options.maxConcurrentSizing), candidates.count) { enqueue() }
            while let entry = await group.next() {
                measured += 1
                if let entry {
                    entries.append(entry)
                    bytes += entry.size
                }
                if gate.shouldEmit(force: measured == candidates.count) {
                    progress(CleanupScanProgress(stage: .measuring, currentPath: entry?.url.path, measured: measured,
                                                 total: candidates.count, foundCount: entries.count, foundBytes: bytes))
                }
                if next < candidates.count, !flag.isCancelled { enqueue() }
            }
        }
        entries.sort { $0.size != $1.size ? $0.size > $1.size : $0.url.path < $1.url.path }
        return CleanupScanResult(entries: entries, inaccessiblePaths: inaccessible, wasCancelled: flag.isCancelled)
    }

    // MARK: - Item

    static func makeEntry(_ candidate: CleanupCandidate, options: Options, running: CleanupRunningSet,
                          flag: CleanupCancelFlag) -> CleanupEntry? {
        let size = FileSizer.allocatedSize(of: candidate.url, isCancelled: { flag.isCancelled })
        guard size > 0, !flag.isCancelled else { return nil }

        let owners = ownerBundleIDs(candidate)
        var isRunning = isRunning(owners: owners, running: running.bundleIDs)
        if !isRunning, owners.isEmpty, case .itemName = candidate.rule.owner,
           let top = candidate.relativeComponents.first {
            isRunning = running.names.contains(top.lowercased())
        }
        var bundleID = owners.first { !$0.hasSuffix(".*") }
        if bundleID == nil, case .app = candidate.rule.label, let top = candidate.relativeComponents.first,
           CleanupAppResolver.looksLikeBundleID(top) {
            bundleID = top   // registros com nome de bundle ID: só para o rótulo
        }
        let app = bundleID.flatMap { options.resolver.app(for: $0) }
        let labeled = CleanupLabels.label(for: candidate, bundleID: bundleID, app: app)
        let recommended = candidate.categoryRecommended && candidate.rule.isRecommended && !isRunning && !candidate.isActive

        return CleanupEntry(url: candidate.url, size: size, category: candidate.categoryID,
                            label: labeled.label, detail: labeled.detail, bundleID: bundleID, appURL: app?.url,
                            isAppRunning: isRunning, isActive: candidate.isActive,
                            lastModified: labeled.date ?? candidate.modified,
                            isRecommended: recommended, note: candidate.rule.note)
    }

    static func ownerBundleIDs(_ candidate: CleanupCandidate) -> [String] {
        switch candidate.rule.owner {
        case .none: return []
        case .fixed(let ids): return ids
        case .wildcard: return candidate.captures.first.map { [$0] } ?? []
        case .itemName:
            guard let top = candidate.relativeComponents.first else { return [] }
            let id = CleanupLabels.stripSavedState(top)
            return CleanupAppResolver.looksLikeBundleID(id) ? [id] : []
        }
    }

    /// Algum dono está aberto? Também vale para ajudantes e extensões do app aberto
    /// (`com.empresa.app.helper` quando `com.empresa.app` está rodando). `running` em minúsculas.
    static func isRunning(owners: [String], running: Set<String>) -> Bool {
        guard !running.isEmpty else { return false }
        for owner in owners.map({ $0.lowercased() }) {
            if owner.hasSuffix(".*") {
                let prefix = String(owner.dropLast())
                if running.contains(where: { $0.hasPrefix(prefix) }) { return true }
                continue
            }
            if running.contains(owner) { return true }
            var parts = owner.split(separator: ".")
            while parts.count > 3 {
                parts.removeLast()
                if running.contains(parts.joined(separator: ".")) { return true }
            }
        }
        return false
    }

    // MARK: - Execução fora do pool de concorrência

    /// Leitura de disco é bloqueante: roda numa fila própria para não prender as threads do Swift Concurrency.
    private static let ioQueue = DispatchQueue(label: "CleanerCRTV.cleanup.io", qos: .userInitiated, attributes: .concurrent)

    static func offload<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Apps abertos, normalizados em minúsculas.
struct CleanupRunningSet: Sendable {
    let bundleIDs: Set<String>
    let names: Set<String>

    init(bundleIDs: Set<String>, names: Set<String>) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.names = Set(names.map { $0.lowercased() })
    }
}

/// Sinal de cancelamento visível de dentro das leituras de disco.
final class CleanupCancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// Limita os avisos de progresso a ~10 por segundo.
final class CleanupProgressGate: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let interval: UInt64 = 100_000_000

    func shouldEmit(force: Bool = false) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return last.withLock { last in
            guard force || now &- last >= interval else { return false }
            last = now
            return true
        }
    }
}
