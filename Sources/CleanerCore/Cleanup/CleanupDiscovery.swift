import Darwin
import Foundation

/// Um caminho achado por uma regra, ainda sem tamanho.
struct CleanupCandidate: Sendable {
    let url: URL
    /// Caminho padronizado (chave de reivindicação).
    let path: String
    let categoryID: CleanupCategoryID
    let categoryRecommended: Bool
    let rule: CleanupRule
    /// Pasta de onde o item foi tirado (a listada, ou a mãe em regras `.itself`): base dos rótulos relativos.
    let base: String
    /// Valores dos `*` do padrão.
    let captures: [String]
    let isDirectory: Bool
    let modified: Date?
    var isActive = false

    /// Componentes do caminho a partir da pasta-base.
    var relativeComponents: [String] {
        guard path.count > base.count + 1, path.hasPrefix(base + "/") else { return [url.lastPathComponent] }
        return path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
    }
}

/// Fase 1 da varredura: percorre as regras na ordem de reivindicação e resolve sobreposições.
/// Usada numa única thread (fora da main) — não é compartilhada.
final class CleanupDiscovery {
    private let options: CleanupScanner.Options
    private let cancel: CleanupCancelFlag
    private let onPath: (String) -> Void
    private let homePath: String
    private let homeReal: String
    private let excluded: [String]
    private let fm = FileManager.default

    private(set) var inaccessible = Set<String>()
    /// Caminhos já reivindicados e todos os seus ancestrais (para achar quem "contém" um item reivindicado).
    /// Chaves em minúsculas: o APFS ignora maiúsculas, e o caminho escrito numa regra (`com.apple.Safari`)
    /// pode diferir do nome listado no disco (`com.apple.safari`) — sem isso o mesmo item sairia duas vezes.
    private var claimed = Set<String>()
    private var claimedAncestors = Set<String>()
    private var excludedAncestors = Set<String>()

    static let maxSplitDepth = 4
    static let listingKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .addedToDirectoryDateKey,
    ]

    init(options: CleanupScanner.Options, excluded: [String], cancel: CleanupCancelFlag, onPath: @escaping (String) -> Void) {
        self.options = options
        self.cancel = cancel
        self.onPath = onPath
        // Ignorar a mais nunca é perigoso: compara sem maiúsculas, como o APFS.
        self.excluded = excluded.map { $0.lowercased() }
        homePath = options.home.standardizedFileURL.path
        homeReal = SafetyGuard.realpathString(homePath) ?? homePath
        for path in self.excluded { insertAncestors(of: path, into: &excludedAncestors) }
    }

    /// Candidatos de todas as categorias pedidas, sem repetição e sem pai + filho.
    func run(_ catalog: [CleanupCategory]) -> [CleanupCandidate] {
        let ordered = catalog.enumerated()
            .filter { options.categories.contains($0.element.id) }
            .sorted { ($0.element.claimOrder, $0.offset) < ($1.element.claimOrder, $1.offset) }
            .map(\.element)
        var result: [CleanupCandidate] = []
        for category in ordered {
            for rule in category.rules {
                if cancel.isCancelled { return result }
                for candidate in discover(rule, in: category) {
                    result.append(contentsOf: claim(candidate, depth: 0))
                }
            }
        }
        return result
    }

    // MARK: - Reivindicação

    /// Mesmo caminho ou dentro de um já reivindicado → fora. Contém um reivindicado (ou ignorado) →
    /// divide em filhos quando a regra permite; senão fica fora.
    func claim(_ candidate: CleanupCandidate, depth: Int) -> [CleanupCandidate] {
        let path = candidate.path.lowercased()
        if isInsideClaimed(path) { return [] }
        if claimedAncestors.contains(path) || excludedAncestors.contains(path) {
            guard candidate.rule.splitsAroundClaims, candidate.isDirectory, depth < Self.maxSplitDepth else { return [] }
            guard let children = list(candidate.url) else { return [] }
            return children.compactMap { child in
                makeCandidate(child, rule: candidate.rule, categoryID: candidate.categoryID,
                              recommended: candidate.categoryRecommended, base: candidate.base, captures: candidate.captures)
            }
            .flatMap { claim($0, depth: depth + 1) }
        }
        claimed.insert(path)
        insertAncestors(of: path, into: &claimedAncestors)
        return [candidate]
    }

    private func isInsideClaimed(_ path: String) -> Bool {
        var current = path
        while current.count > 1 {
            if claimed.contains(current) { return true }
            current = Self.parent(of: current)
        }
        return false
    }

    private func insertAncestors(of path: String, into set: inout Set<String>) {
        var current = Self.parent(of: path)
        while current.count > 1 {
            // Se o pai já está, os avós também estão.
            if !set.insert(current).inserted { break }
            current = Self.parent(of: current)
        }
    }

    /// Caminhos protegidos com `*` viram os caminhos que existem agora (links e arquivos também entram).
    /// Os que não existem ficam de fora: senão a pasta-mãe seria dividida (ou descartada) à toa.
    static func expandProtected(_ patterns: [String], home: URL) -> [String] {
        let root = home.standardizedFileURL.path
        return patterns.flatMap { pattern -> [String] in
            var current = [root]
            for component in pattern.split(separator: "/").map(String.init) {
                if component == "*" {
                    current = current.flatMap { dir in
                        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }
                    }
                } else {
                    current = current.map { $0 + "/" + component }
                }
            }
            return current.filter { FileSizer.exists(URL(fileURLWithPath: $0)) }
        }
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    // MARK: - Regras

    func discover(_ rule: CleanupRule, in category: CleanupCategory) -> [CleanupCandidate] {
        if rule.needsFullDiskAccess, !options.hasFullDiskAccess {
            // Ler contêineres de outros apps sem o acesso faz o macOS pedir permissão no meio da varredura:
            // a regra é pulada e conta como pasta que precisa do acesso.
            let root = rule.pattern.components(separatedBy: "/*").first ?? rule.pattern
            if FileSizer.exists(URL(fileURLWithPath: homePath).appendingPathComponent("Library/Containers")) {
                inaccessible.insert(homePath + "/" + root)
            }
            return []
        }

        var found: [CleanupCandidate] = []
        for (baseURL, captures) in expand(rule) {
            if cancel.isCancelled { break }
            let basePath = baseURL.standardizedFileURL.path
            if isExcluded(basePath) { continue }
            onPath(basePath)
            switch rule.mode {
            case .itself:
                guard let item = info(of: baseURL) else { continue }
                if item.isDirectory, !Self.isReadableDirectory(basePath) {
                    inaccessible.insert(basePath)
                    continue
                }
                if let candidate = makeCandidate(item, rule: rule, categoryID: category.id,
                                                 recommended: category.isRecommended,
                                                 base: Self.parent(of: basePath), captures: captures) {
                    found.append(candidate)
                }
            case .children:
                guard let children = list(baseURL) else { continue }
                var fromBase: [CleanupCandidate] = []
                for child in children {
                    if cancel.isCancelled { break }
                    guard let candidate = makeCandidate(child, rule: rule, categoryID: category.id,
                                                        recommended: category.isRecommended, base: basePath, captures: captures)
                    else { continue }
                    // Pasta protegida pelo macOS (sem Acesso Total ao Disco): não dá para medir nem limpar.
                    if candidate.isDirectory, !Self.isReadableDirectory(candidate.path) {
                        inaccessible.insert(candidate.path)
                        continue
                    }
                    fromBase.append(candidate)
                }
                if rule.filter.keepNewestVersion { fromBase = Self.olderVersions(fromBase) }
                found.append(contentsOf: fromBase)
            }
        }

        guard let window = rule.activeWindow else { return found }
        let threshold = options.now.addingTimeInterval(-window)
        return found.compactMap { candidate in
            var candidate = candidate
            if candidate.isDirectory {
                candidate.isActive = hasContent(in: candidate.url, modifiedAfter: threshold)
            } else if let modified = candidate.modified, modified > threshold {
                return nil   // sendo gravado agora
            }
            return candidate
        }
    }

    /// Troca cada `*` pelas subpastas reais. Só devolve pastas-base que estão de fato onde o padrão diz
    /// (sem atalhos no meio do caminho levando para outro lugar).
    func expand(_ rule: CleanupRule) -> [(URL, [String])] {
        var current: [(URL, [String])] = [(URL(fileURLWithPath: homePath, isDirectory: true), [])]
        for component in rule.pattern.split(separator: "/").map(String.init) {
            var next: [(URL, [String])] = []
            for (url, captures) in current {
                if component == "*" {
                    guard let children = list(url) else { continue }
                    for child in children where child.isDirectory && !child.isSymlink && !child.name.hasPrefix(".") {
                        if let accepts = rule.filter.wildcardAccepts, !accepts(child.name) { continue }
                        next.append((child.url, captures + [child.name]))
                    }
                } else {
                    next.append((url.appendingPathComponent(component, isDirectory: true), captures))
                }
            }
            current = next
        }
        return current.filter { isRealLocation($0.0) }
    }

    private func isRealLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            if errno == EPERM || errno == EACCES { inaccessible.insert(path) }
            return false
        }
        defer { free(resolved) }
        let expected = homeReal + path.dropFirst(homePath.count)
        // APFS costuma ignorar maiúsculas: compara do mesmo jeito.
        return String(cString: resolved).lowercased() == expected.lowercased()
    }

    // MARK: - Filtros

    func makeCandidate(_ item: CleanupListedItem, rule: CleanupRule, categoryID: CleanupCategoryID,
                       recommended: Bool, base: String, captures: [String]) -> CleanupCandidate? {
        guard Self.accepts(item, filter: rule.filter, now: options.now) else { return nil }
        let path = item.url.standardizedFileURL.path
        guard !isExcluded(path), options.isAllowed(item.url) else { return nil }
        return CleanupCandidate(url: item.url, path: path, categoryID: categoryID, categoryRecommended: recommended,
                                rule: rule, base: base, captures: captures, isDirectory: item.isDirectory,
                                modified: item.modified)
    }

    static func accepts(_ item: CleanupListedItem, filter: CleanupFilter, now: Date) -> Bool {
        let name = item.name
        let lower = name.lowercased()
        if lower == ".ds_store" || lower == ".localized" { return false }
        if name.hasPrefix("."), !filter.includeHidden { return false }
        if filter.excludedNames.contains(lower) { return false }
        if filter.excludedPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        if let extensions = filter.extensions, !extensions.contains((name as NSString).pathExtension.lowercased()) {
            return false
        }
        switch filter.kind {
        case .any: break
        case .files: if item.isDirectory { return false }
        case .directories: if !item.isDirectory || item.isSymlink { return false }
        }
        if let minAge = filter.minAge {
            // A data mais recente entre modificação e chegada na pasta: um download antigo baixado ontem é novo.
            guard let date = [item.modified, item.added].compactMap({ $0 }).max(),
                  now.timeIntervalSince(date) >= minAge else { return false }
        }
        return true
    }

    private func isExcluded(_ path: String) -> Bool {
        !excluded.isEmpty && Exclusions.isExcluded(path: path.lowercased(), in: excluded)
    }

    /// Suporte a dispositivos: fica a versão mais nova; as anteriores viram itens. Sem versão legível, nada sai.
    static func olderVersions(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        let versioned = candidates.compactMap { c in CleanupLabels.version(in: c.url.lastPathComponent).map { (c, $0) } }
        guard let newest = versioned.map(\.1).max(by: { CleanupLabels.compare($0, $1) < 0 }) else { return [] }
        return versioned.filter { CleanupLabels.compare($0.1, newest) < 0 }.map(\.0)
    }

    // MARK: - Disco

    /// Filhos de uma pasta. nil = não existe ou não pode ser lida (sem permissão entra na conta).
    func list(_ url: URL) -> [CleanupListedItem]? {
        do {
            let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.listingKeys, options: [])
            return urls.compactMap(CleanupListedItem.init(url:))
        } catch {
            if Self.isPermissionError(error) { inaccessible.insert(url.standardizedFileURL.path) }
            return nil
        }
    }

    private func info(of url: URL) -> CleanupListedItem? {
        guard FileSizer.exists(url) else { return nil }
        return CleanupListedItem(url: url)
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EPERM) || underlying.code == Int(EACCES)
        }
        return false
    }

    static func isReadableDirectory(_ path: String) -> Bool {
        guard let dir = opendir(path) else { return !(errno == EPERM || errno == EACCES) }
        closedir(dir)
        return true
    }

    /// Algo dentro da pasta mudou depois de `date`? Para no primeiro achado.
    private func hasContent(in url: URL, modifiedAfter date: Date) -> Bool {
        if let modified = info(of: url)?.modified, modified > date { return true }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [], errorHandler: { _, _ in true }) else { return false }
        for case let child as URL in enumerator {
            if cancel.isCancelled { return false }
            if let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified > date { return true }
        }
        return false
    }
}

/// Item listado numa pasta, com os metadados que os filtros usam (lidos sem seguir links).
struct CleanupListedItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let modified: Date?
    let added: Date?

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(CleanupDiscovery.listingKeys)) else { return nil }
        self.url = url
        name = url.lastPathComponent
        isSymlink = values.isSymbolicLink ?? false
        isDirectory = (values.isDirectory ?? false) && !isSymlink
        modified = values.contentModificationDate
        added = values.addedToDirectoryDate
    }

    init(url: URL, name: String, isDirectory: Bool, isSymlink: Bool = false, modified: Date?, added: Date? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.modified = modified
        self.added = added
    }
}
