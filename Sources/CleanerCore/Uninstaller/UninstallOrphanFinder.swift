import AppKit
import Foundation

/// O que ajuda a decidir se um identificador ainda tem dono.
public struct UninstallOrphanContext: Sendable {
    /// Identificadores dos apps instalados e dos pacotes dentro deles (minúsculas).
    public var installedIDs: Set<String>
    /// Apps e agentes abertos agora (minúsculas).
    public var runningIDs: Set<String>
    /// Labels de agentes/daemons do launchd cujo programa existe (minúsculas).
    public var liveAgentLabels: Set<String>
    /// Contêineres de grupo que algum app instalado declara na assinatura (nome completo, minúsculas).
    public var claimedGroups: Set<String>

    public init(installedIDs: Set<String>, runningIDs: Set<String> = [], liveAgentLabels: Set<String> = [],
                claimedGroups: Set<String> = []) {
        self.installedIDs = Set(installedIDs.map { $0.lowercased() })
        self.runningIDs = Set(runningIDs.map { $0.lowercased() })
        self.liveAgentLabels = Set(liveAgentLabels.map { $0.lowercased() })
        self.claimedGroups = Set(claimedGroups.map { $0.lowercased() })
    }
}

/// Restos de apps que já saíram do Mac. Conservador de propósito: um falso positivo apaga dado de verdade.
///
/// Um item só entra se o nome é um identificador reverso (com.empresa.app) e:
/// - não é da Apple, de biblioteca/atualizador compartilhado, nem do próprio CleanerCRTV;
/// - nenhum app instalado tem esse identificador, um "pai" dele ou um "filho" dele;
/// - nada instalado (app, plug-in, ajudante) ou aberto é do mesmo fabricante (com.empresa.*);
/// - nenhum app instalado (nem do sistema) declara o contêiner de grupo na assinatura;
/// - nenhum agente do launchd vivo usa o identificador, e o LaunchServices não conhece app com ele;
/// - nada dentro dele mudou nos últimos 30 dias (pode ser de ferramenta de linha de comando ou serviço).
/// Agentes de início só contam quando o programa que eles chamam não existe mais.
public enum UninstallOrphanFinder {
    public static let minimumAge: TimeInterval = 30 * 86_400

    /// Regras puras (sem disco). Devolve o identificador dono se o item é candidato.
    public static func candidateKey(for entry: UninstallLibraryEntry, context: UninstallOrphanContext) -> String? {
        guard var key = entry.key else { return nil }
        if entry.location.allowsGroupPrefix, context.claimedGroups.contains(entry.name.lowercased()) { return nil }
        if entry.location == .launchAgents {
            guard let agent = entry.agent, agent.program != nil, !agent.programExists else { return nil }
            if let label = agent.label?.lowercased(), UninstallBundleID.looksLikeBundleID(label) { key = label }
        }
        guard UninstallBundleID.looksLikeBundleID(key), !UninstallBundleID.isShared(key) else { return nil }
        if entry.name.lowercased().hasPrefix("group.com.apple") { return nil }
        if hasFamily(key, in: context.installedIDs, sameVendor: true) { return nil }
        if hasFamily(key, in: context.runningIDs, sameVendor: true) { return nil }
        if hasFamily(key, in: context.liveAgentLabels, sameVendor: false) { return nil }
        return key
    }

    /// Mesmo identificador, pai, filho ou (opcional) mesmo fabricante.
    static func hasFamily(_ key: String, in ids: Set<String>, sameVendor: Bool) -> Bool {
        if ids.contains(key) { return true }
        let vendor = UninstallBundleID.vendor(of: key)
        return ids.contains { id in
            UninstallBundleID.isSame(key, orChildOf: id) || UninstallBundleID.isSame(id, orChildOf: key)
                || (sameVendor && UninstallBundleID.vendor(of: id) == vendor)
        }
    }

    /// Varre, filtra, mede e agrupa. `isRegistered` pergunta se existe app com o identificador em qualquer lugar.
    /// `known`: o que mais está instalado (plug-ins, apps fundos, apps do sistema…); nil = lê do disco.
    @concurrent
    public static func find(
        installed: [UninstallApp],
        runningIDs: Set<String>,
        index: UninstallLibraryIndex,
        filter: UninstallFilter = .live(),
        isRegistered: @escaping @Sendable (String) -> Bool = { UninstallOrphanFinder.isRegisteredApp($0) },
        known: UninstallKnownBundles.Snapshot? = nil,
        liveAgentLabels: Set<String>? = nil,
        now: Date = Date(),
        concurrency: Int = 4
    ) async -> [UninstallOrphanGroup] {
        let home = index.library.deletingLastPathComponent()
        let known = known ?? UninstallKnownBundles.collect(home: home)
        if Task.isCancelled { return [] }
        let context = UninstallOrphanContext(
            installedIDs: Set(installed.flatMap(\.allIDs)).union(known.ids),
            runningIDs: runningIDs,
            liveAgentLabels: liveAgentLabels ?? Self.liveAgentLabels(index: index),
            claimedGroups: Set(installed.flatMap(\.appGroups)).union(known.groups)
        )
        var registered: [String: Bool] = [:]
        var candidates: [(entry: UninstallLibraryEntry, key: String)] = []
        for entry in index.entries {
            if Task.isCancelled { return [] }
            guard let key = candidateKey(for: entry, context: context), filter.allows(entry.url) else { continue }
            let lookup = entry.location == .launchAgents ? key : (entry.rawKey ?? key)
            let known = registered[key] ?? isRegistered(lookup)
            registered[key] = known
            if !known { candidates.append((entry, key)) }
        }

        let measured = await UninstallConcurrency.map(candidates, limit: concurrency) { candidate in
            UninstallMeasure.measure(candidate.entry.url, isCancelled: { Task.isCancelled })
        }
        if Task.isCancelled { return [] }

        let cutoff = now.addingTimeInterval(-minimumAge)
        var items: [UninstallLeftover] = []
        for (i, candidate) in candidates.enumerated() {
            guard let m = measured[i] else { continue }
            // Sem data legível não dá para saber se está em uso: fica de fora.
            guard let newest = [m.newest, candidate.entry.modified].compactMap({ $0 }).max(), newest < cutoff else { continue }
            items.append(UninstallLeftover(url: candidate.entry.url, kind: candidate.entry.location.kind, confidence: .medium,
                                           ownerKey: candidate.key, size: m.bytes, modified: newest))
        }
        return group(items)
    }

    /// Mesma busca, lendo ~/Library de `home` na hora.
    @concurrent
    public static func find(
        installed: [UninstallApp],
        runningIDs: Set<String>,
        home: URL = Paths.home,
        filter: UninstallFilter = .live(),
        isRegistered: @escaping @Sendable (String) -> Bool = { UninstallOrphanFinder.isRegisteredApp($0) },
        known: UninstallKnownBundles.Snapshot? = nil,
        liveAgentLabels: Set<String>? = nil,
        now: Date = Date(),
        concurrency: Int = 4
    ) async -> [UninstallOrphanGroup] {
        let index = UninstallLibraryIndex.build(home: home)
        return await find(installed: installed, runningIDs: runningIDs, index: index, filter: filter,
                          isRegistered: isRegistered, known: known, liveAgentLabels: liveAgentLabels,
                          now: now, concurrency: concurrency)
    }

    /// Junta por identificador; ajudantes ("com.foo.app.helper") entram no grupo do pai quando ele também aparece.
    public static func group(_ items: [UninstallLeftover]) -> [UninstallOrphanGroup] {
        let keys = Set(items.map(\.ownerKey))
        func root(of key: String) -> String {
            keys.filter { UninstallBundleID.isSame(key, orChildOf: $0) }.min { $0.count < $1.count } ?? key
        }
        return Dictionary(grouping: items) { root(of: $0.ownerKey) }
            .map { UninstallOrphanGroup(key: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.size == $1.size ? $0.key < $1.key : $0.size > $1.size }
    }

    // MARK: - Fontes do sistema

    /// Labels de agentes e daemons cujo programa ainda existe (os do sistema contam sempre).
    static func liveAgentLabels(index: UninstallLibraryIndex) -> Set<String> {
        var labels = Set<String>()
        for entry in index.entries where entry.location == .launchAgents {
            if let agent = entry.agent, agent.programExists, let label = agent.label { labels.insert(label.lowercased()) }
        }
        for folder in ["/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            for url in urls {
                if let label = UninstallLibraryIndex.readAgent(url)?.label { labels.insert(label.lowercased()) }
            }
        }
        return labels
    }

    /// Existe app com esse identificador (ou com um "pai" dele) registrado no LaunchServices, fora da Lixeira?
    public static func isRegisteredApp(_ key: String) -> Bool {
        var parts = key.split(separator: ".").map(String.init)
        let fm = FileManager.default
        while parts.count >= 3 {
            let id = parts.joined(separator: ".")
            let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            if urls.contains(where: { !$0.path.contains("/.Trash/") && fm.fileExists(atPath: $0.path) }) { return true }
            parts.removeLast()
        }
        return false
    }
}
