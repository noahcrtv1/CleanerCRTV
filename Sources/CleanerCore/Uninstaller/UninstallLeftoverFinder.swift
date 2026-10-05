import Foundation

/// Acha o que um app deixa em ~/Library.
///
/// Regras (nunca por pedaço de nome):
/// - identificador idêntico ao do app, ou de um ajudante dele ("com.foo.app.helper") → confiança alta;
///   se outro app instalado tem um identificador mais específico que também casa, o item é dele;
/// - contêiner de grupo "group.<id>" → alta; "<EQUIPE>.<id>" → alta se a equipe é a da assinatura,
///   média se o app não tem equipe, ignorado se a equipe é outra;
/// - agente de início cujo Label é do app ou cujo programa está dentro do pacote → alta;
/// - pasta com o nome exato do app em Application Support, Caches ou Logs → média.
public enum UninstallLeftoverFinder {
    /// Só regras, sem tocar no disco (tamanhos zerados). `installed` são todos os apps instalados.
    public static func match(app: UninstallApp, in index: UninstallLibraryIndex, installed: [UninstallApp]) -> [UninstallLeftover] {
        let ownIDs = Set(app.matchIDs)
        let mainID = app.bundleID?.lowercased()
        var allIDs = Set(installed.flatMap(\.allIDs))
        allIDs.formUnion(ownIDs)
        let others = installed.filter { $0.url != app.url }
        let otherNames = Set(others.flatMap(\.matchNames))
        let ownNames = Set(app.matchNames).subtracting(otherNames)
        let appPath = app.url.standardizedFileURL.path + "/"

        func ownedKey(_ key: String) -> Bool {
            guard ownIDs.contains(where: { UninstallBundleID.isSame(key, orChildOf: $0) }) else { return false }
            guard let owner = UninstallBundleID.owner(of: key, among: allIDs) else { return false }
            return ownIDs.contains(owner)
        }

        var results: [UninstallLeftover] = []
        for entry in index.entries {
            var confidence: UninstallConfidence?
            var owner = mainID ?? ""

            if let key = entry.key, ownedKey(key) {
                owner = key
                if let team = entry.teamPrefix {
                    if let appTeam = app.teamID {
                        confidence = appTeam.caseInsensitiveCompare(team) == .orderedSame ? .high : nil
                    } else {
                        confidence = .medium
                    }
                } else {
                    confidence = .high
                }
            }

            if confidence == nil, entry.location == .launchAgents, let agent = entry.agent {
                if let label = agent.label?.lowercased(), ownedKey(label) {
                    confidence = .high
                    owner = label
                } else if let program = agent.program, program.hasPrefix(appPath)
                            || agent.arguments.contains(where: { $0.contains(appPath) }) {
                    confidence = .high
                }
            }

            if confidence == nil, entry.location.allowsNameMatch, ownNames.contains(entry.name.lowercased()) {
                confidence = .medium
            }

            if let confidence {
                results.append(UninstallLeftover(url: entry.url, kind: entry.location.kind, confidence: confidence,
                                                 ownerKey: owner, modified: entry.modified))
            }
        }
        return results
    }

    /// Restos de cada app, já filtrados (guarda + pastas ignoradas) e medidos.
    /// Apps que não podem ser removidos (Apple, o próprio) não têm restos procurados.
    @concurrent
    public static func find(
        for apps: [UninstallApp],
        installed: [UninstallApp],
        home: URL = Paths.home,
        filter: UninstallFilter = .live(),
        concurrency: Int = 4
    ) async -> [URL: [UninstallLeftover]] {
        let index = UninstallLibraryIndex.build(home: home)
        var pending: [(app: URL, item: UninstallLeftover)] = []
        var result: [URL: [UninstallLeftover]] = [:]
        for app in apps {
            result[app.url] = []
            guard app.canUninstall else { continue }
            for item in match(app: app, in: index, installed: installed) where filter.allows(item.url) {
                pending.append((app.url, item))
            }
        }
        let measured = await UninstallConcurrency.map(pending, limit: concurrency) { pair in
            UninstallMeasure.measure(pair.item.url, isCancelled: { Task.isCancelled })
        }
        if Task.isCancelled { return [:] }
        for (index, pair) in pending.enumerated() {
            var item = pair.item
            if let m = measured[index] {
                item.size = m.bytes
                item.modified = m.newest ?? item.modified
            }
            result[pair.app, default: []].append(item)
        }
        for key in result.keys {
            result[key]?.sort { ($0.kind.order, -$0.size) < ($1.kind.order, -$1.size) }
        }
        return result
    }
}
