import Darwin
import Foundation

/// Qual cópia de cada grupo fica quando a seleção é automática.
public enum DuplicateKeepRule: Sendable, Hashable {
    case oldest
    case newest
    /// Fica a cópia dentro desta pasta (a mais antiga, se houver várias). Sem nenhuma lá, vale a mais antiga.
    case inFolder(URL)

    public var title: String {
        switch self {
        case .oldest: "Manter o mais antigo"
        case .newest: "Manter o mais novo"
        case .inFolder(let url): "Manter o que está em “\(url.lastPathComponent)”"
        }
    }
}

/// O que de fato vai para a remoção depois de conferir o disco de novo.
public struct DuplicateRemovalPlan: Sendable {
    public var items: [RemovalItem] = []
    /// Cópias marcadas que ficaram de fora (mudaram, sumiram, ou o grupo ficaria sem nenhuma cópia).
    public var skipped = 0
    /// Bytes que voltam ao disco (clones e links físicos liberam pouco ou nada).
    public var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Regras de seleção. Invariante: um grupo nunca fica com todas as cópias marcadas.
public enum DuplicateSelector {
    public static func keeper(of files: [DuplicateFile], rule: DuplicateKeepRule) -> DuplicateFile? {
        keeper(of: files, rule: rule, folderPrefix: folderPrefix(rule))
    }

    /// `folderPrefix` já canônico: em lote, o realpath da pasta preferida roda uma vez só.
    static func keeper(of files: [DuplicateFile], rule: DuplicateKeepRule, folderPrefix: String?) -> DuplicateFile? {
        switch rule {
        case .oldest:
            return files.min { precedes($0, $1, newestFirst: false) }
        case .newest:
            return files.min { precedes($0, $1, newestFirst: true) }
        case .inFolder:
            guard let prefix = folderPrefix else { return files.min { precedes($0, $1, newestFirst: false) } }
            let inside = files.filter { contains(folder: prefix, $0.url) }
            return (inside.isEmpty ? files : inside).min { precedes($0, $1, newestFirst: false) }
        }
    }

    static func folderPrefix(_ rule: DuplicateKeepRule) -> String? {
        if case .inFolder(let folder) = rule { return DuplicateRoots.canonical(folder) }
        return nil
    }

    /// Marca tudo menos a cópia que fica em cada grupo. Grupos de clones APFS ficam de fora:
    /// remover não libera espaço.
    public static func autoSelect(_ groups: [DuplicateGroup], rule: DuplicateKeepRule,
                                  includeClones: Bool = false) -> Set<URL> {
        var selection = Set<URL>()
        let prefix = folderPrefix(rule)
        for group in groups where group.files.count > 1 {
            if group.isCloneGroup, !includeClones { continue }
            selection.formUnion(selectionKeepingOne(group, rule: rule, folderPrefix: prefix))
        }
        return selection
    }

    /// Todas as cópias do grupo menos a que fica pela regra.
    public static func selectionKeepingOne(_ group: DuplicateGroup, rule: DuplicateKeepRule) -> Set<URL> {
        selectionKeepingOne(group, rule: rule, folderPrefix: folderPrefix(rule))
    }

    static func selectionKeepingOne(_ group: DuplicateGroup, rule: DuplicateKeepRule, folderPrefix: String?) -> Set<URL> {
        guard group.files.count > 1,
              let keep = keeper(of: group.files, rule: rule, folderPrefix: folderPrefix) else { return [] }
        return Set(group.files.lazy.filter { $0.url != keep.url }.map(\.url))
    }

    /// Marca/desmarca uma cópia. Marcar a última cópia desmarcada do grupo é recusado.
    public static func toggle(_ url: URL, in group: DuplicateGroup,
                              selection: Set<URL>) -> (selection: Set<URL>, refused: Bool) {
        var result = selection
        if result.remove(url) != nil { return (result, false) }
        guard group.files.contains(where: { $0.url == url }) else { return (selection, false) }
        let unselected = group.files.reduce(0) { $0 + (result.contains($1.url) ? 0 : 1) }
        guard unselected > 1 else { return (selection, true) }
        result.insert(url)
        return (result, false)
    }

    /// Caixa do grupo: com alguma cópia marcada, desmarca todas; sem nenhuma, marca todas menos a que fica.
    public static func toggleGroup(_ group: DuplicateGroup, rule: DuplicateKeepRule,
                                   selection: Set<URL>) -> Set<URL> {
        var result = selection
        let urls = group.files.map(\.url)
        if urls.contains(where: result.contains) {
            result.subtract(urls)
        } else {
            result.formUnion(selectionKeepingOne(group, rule: rule))
        }
        return result
    }

    /// "Manter só esta": marca todas as outras cópias do grupo e desmarca esta.
    public static func keepOnly(_ url: URL, in group: DuplicateGroup, selection: Set<URL>) -> Set<URL> {
        guard group.files.contains(where: { $0.url == url }) else { return selection }
        var result = selection
        result.formUnion(group.files.lazy.map(\.url).filter { $0 != url })
        result.remove(url)
        return result
    }

    /// Garante pelo menos uma cópia desmarcada por grupo (libera a que a regra manteria).
    public static func enforcingKeep(_ selection: Set<URL>, in groups: [DuplicateGroup],
                                     rule: DuplicateKeepRule = .oldest) -> Set<URL> {
        var result = selection
        let prefix = folderPrefix(rule)
        for group in groups where !group.files.isEmpty && group.files.allSatisfy({ result.contains($0.url) }) {
            if let keep = keeper(of: group.files, rule: rule, folderPrefix: prefix) { result.remove(keep.url) }
        }
        return result
    }

    /// Confere no disco, logo antes de remover, que cada cópia marcada continua igual à da varredura
    /// e que pelo menos uma cópia desmarcada do grupo ainda existe intacta.
    public static func removalPlan(groups: [DuplicateGroup], selection: Set<URL>) -> DuplicateRemovalPlan {
        var plan = DuplicateRemovalPlan()
        for group in groups {
            let chosen = group.files.filter { selection.contains($0.url) }
            guard !chosen.isEmpty else { continue }
            let kept = group.files.filter { !selection.contains($0.url) }
            guard kept.contains(where: { isUnchanged($0, size: group.size) }) else {
                plan.skipped += chosen.count
                continue
            }
            let removable = chosen.filter { isUnchanged($0, size: group.size) }
            plan.skipped += chosen.count - removable.count
            let freed = group.freedBytes(removing: Set(removable.map(\.url)))
            plan.items += removable.map { RemovalItem(url: $0.url, size: freed[$0.url] ?? $0.allocatedSize) }
        }
        return plan
    }

    // MARK: - Interno

    /// Mais antigo (ou mais novo) primeiro; empate: o caminho mais raso, depois ordem alfabética.
    static func precedes(_ a: DuplicateFile, _ b: DuplicateFile, newestFirst: Bool) -> Bool {
        switch (a.originDate, b.originDate) {
        case let (x?, y?) where x != y: return newestFirst ? x > y : x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let depthA = a.url.pathComponents.count
        let depthB = b.url.pathComponents.count
        if depthA != depthB { return depthA < depthB }
        return a.url.path < b.url.path
    }

    /// Ordem de exibição: o "original" provável primeiro.
    static func sortedByOrigin(_ files: [DuplicateFile]) -> [DuplicateFile] {
        files.sorted { precedes($0, $1, newestFirst: false) }
    }

    static func contains(folder: String, _ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    static func isUnchanged(_ file: DuplicateFile, size: Int64) -> Bool {
        var st = stat()
        guard lstat(file.url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int64(st.st_size) == size else {
            return false
        }
        if file.inode != 0, st.st_ino != file.inode || st.st_dev != file.device { return false }
        if let modified = file.modified, DuplicateScanner.date(st.st_mtimespec) != modified { return false }
        return true
    }
}
