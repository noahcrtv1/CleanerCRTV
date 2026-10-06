import Foundation

/// Acha o que um app deixa em ~/Library.
///
/// Regras (nunca por pedaço de nome):
/// - identificador idêntico ao do app, ou de um ajudante dele ("com.foo.app.helper") → confiança alta;
///   ajudante embutido com outro identificador do mesmo fabricante → média;
///   se outro app instalado tem um identificador mais específico que também casa, o item é dele;
///   identificador que outro app instalado também traz (outra cópia, ajudante comum) não conta;
/// - contêiner de grupo declarado na assinatura do app → alta; declarado por outro app instalado → nunca;
///   "group.<id>" → como acima; "<EQUIPE>.<id>" → só se a equipe é a da assinatura
///   (média se o app não tem equipe, ignorado se a equipe é outra);
/// - agente de início cujo Label é do app ou cujo programa está dentro do pacote → alta;
/// - pasta com o nome exato do app em Application Support, Caches ou Logs → média.
public enum UninstallLeftoverFinder {
    /// Só regras, sem tocar no disco (tamanhos zerados). `installed` são todos os apps instalados.
    public static func match(app: UninstallApp, in index: UninstallLibraryIndex, installed: [UninstallApp]) -> [UninstallLeftover] {
        let appPath = app.url.standardizedFileURL.path
        let others = installed.filter { $0.url.standardizedFileURL.path != appPath }
        let otherIDs = Set(others.flatMap(\.allIDs))
        let mainID = app.bundleID?.lowercased()
        var ownIDs = Set(app.matchIDs).subtracting(otherIDs)
        if let mainID, otherIDs.contains(mainID) {
            ownIDs = ownIDs.filter { !UninstallBundleID.isSame($0, orChildOf: mainID) }
        }
        let mainIsOwn = mainID.map { ownIDs.contains($0) } ?? false
        let allIDs = otherIDs.union(app.allIDs).union(ownIDs)
        let ownNames = Set(app.matchNames).subtracting(others.flatMap(\.matchNames))
        let ownGroups = Set(app.appGroups)
        let otherGroups = Set(others.flatMap(\.appGroups))
        let bundlePrefix = appPath + "/"

        /// Confiança se `key` pertence a este app; nil se não.
        func ownership(_ key: String) -> UninstallConfidence? {
            guard ownIDs.contains(where: { claims($0, key) }),
                  let owner = UninstallBundleID.owner(of: key, among: allIDs), ownIDs.contains(owner) else { return nil }
            if mainIsOwn, let mainID, claims(mainID, key) { return .high }
            return .medium
        }

        var results: [UninstallLeftover] = []
        for entry in index.entries {
            var confidence: UninstallConfidence?
            var owner = mainID ?? ""

            if entry.location.allowsGroupPrefix {
                let name = entry.name.lowercased()
                // Grupo declarado por outro app instalado: é dele (ou compartilhado), nunca sai junto.
                if otherGroups.contains(name) { continue }
                if ownGroups.contains(name) {
                    results.append(UninstallLeftover(url: entry.url, kind: entry.location.kind, confidence: .high,
                                                     ownerKey: name, modified: entry.modified))
                    continue
                }
            }

            if let key = entry.key, let found = ownership(key) {
                owner = key
                if let team = entry.teamPrefix {
                    if let appTeam = app.teamID {
                        confidence = appTeam.caseInsensitiveCompare(team) == .orderedSame ? found : nil
                    } else {
                        confidence = .medium
                    }
                } else {
                    confidence = found
                }
            }

            if confidence == nil, entry.location == .launchAgents, let agent = entry.agent {
                if let label = agent.label?.lowercased(), let found = ownership(label) {
                    confidence = found
                    owner = label
                } else if let program = agent.program,
                          program.hasPrefix(bundlePrefix) || agent.arguments.contains(where: { $0.hasPrefix(bundlePrefix) }) {
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

    /// `key` é `id` ou filho dele. Um identificador curto ("com.foo") só vale idêntico: senão levaria
    /// tudo do fabricante (com.foo.outroapp…) junto.
    static func claims(_ id: String, _ key: String) -> Bool {
        key == id || (id.split(separator: ".").count >= 3 && key.hasPrefix(id + "."))
    }

    /// Restos de cada app, já filtrados (guarda + pastas ignoradas) e medidos.
    /// Apps que não podem ser removidos (Apple, o próprio) não têm restos procurados.
    @concurrent
    public static func find(
        for apps: [UninstallApp],
        installed: [UninstallApp],
        index: UninstallLibraryIndex,
        filter: UninstallFilter = .live(),
        concurrency: Int = 4
    ) async -> [URL: [UninstallLeftover]] {
        var pending: [(app: URL, item: UninstallLeftover)] = []
        var result: [URL: [UninstallLeftover]] = [:]
        for app in apps {
            result[app.url] = []
            guard app.canUninstall else { continue }
            // O índice pode ser de antes de outra limpeza: o que já sumiu não entra.
            for item in match(app: app, in: index, installed: installed) where FileSizer.exists(item.url) && filter.allows(item.url) {
                pending.append((app.url, item))
            }
        }
        let measured = await UninstallConcurrency.map(pending, limit: concurrency) { pair in
            UninstallMeasure.measure(pair.item.url, isCancelled: { Task.isCancelled })
        }
        if Task.isCancelled { return [:] }
        for (i, pair) in pending.enumerated() {
            var item = pair.item
            if let m = measured[i] {
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

    /// Mesma busca, lendo ~/Library de `home` na hora.
    @concurrent
    public static func find(
        for apps: [UninstallApp],
        installed: [UninstallApp],
        home: URL = Paths.home,
        filter: UninstallFilter = .live(),
        concurrency: Int = 4
    ) async -> [URL: [UninstallLeftover]] {
        let index = UninstallLibraryIndex.build(home: home)
        return await find(for: apps, installed: installed, index: index, filter: filter, concurrency: concurrency)
    }
}
