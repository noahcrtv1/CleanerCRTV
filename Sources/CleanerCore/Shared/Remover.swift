import AppKit
import Foundation

public enum RemovalMode: String, Codable, Sendable, CaseIterable {
    /// Move para a Lixeira (recuperável). Padrão.
    case trash
    /// Apaga de vez. Só com confirmação explícita na interface.
    case permanent

    public var label: String {
        switch self {
        case .trash: "Mover para a Lixeira"
        case .permanent: "Apagar permanentemente"
        }
    }
}

/// Um item a remover, com o tamanho já medido pela varredura (para o relatório e o histórico).
public struct RemovalItem: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    /// Texto curto mostrado na confirmação (ex.: "Cache do Spotify"). Opcional.
    public let label: String?

    public init(url: URL, size: Int64, label: String? = nil) {
        self.url = url
        self.size = size
        self.label = label
    }
}

public struct RemovalFailure: Sendable, Hashable {
    public let url: URL
    public let reason: String
}

public struct RemovalReport: Sendable {
    public var mode: RemovalMode
    /// Itens que saíram do lugar (inclui os que já não existiam).
    public var removed: [URL] = []
    public var failed: [RemovalFailure] = []
    /// Bytes que saíram do lugar. Na Lixeira, o espaço só volta ao esvaziar.
    public var bytes: Int64 = 0

    public var removedSet: Set<URL> { Set(removed) }
}

/// Única porta de saída de arquivos do app. Sempre passa pelo `SafetyGuard` e grava o histórico.
public enum Remover {
    /// Remove em segundo plano. `progress(feitos, total)` é chamado na main.
    public static func remove(
        _ items: [RemovalItem],
        mode: RemovalMode,
        source: String,
        history: HistoryStore = .shared,
        progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async -> RemovalReport {
        var report = RemovalReport(mode: mode)
        // Pais antes dos filhos: se a pasta sai, os filhos listados junto saem com ela.
        let ordered = dedupedByAncestor(items)
        let skippedChildren = Set(items.map(\.url)).subtracting(ordered.map(\.url))

        for (index, item) in ordered.enumerated() {
            if Task.isCancelled { break }
            switch await removeOne(item, mode: mode) {
            case .success:
                report.removed.append(item.url)
                report.bytes += item.size
            case .failure(let reason):
                report.failed.append(RemovalFailure(url: item.url, reason: reason))
            }
            if let progress { await progress(index + 1, ordered.count) }
        }
        // Filhos de pastas removidas também saíram.
        let removedParents = report.removed
        for child in skippedChildren where removedParents.contains(where: { child.path.hasPrefix($0.path + "/") }) {
            report.removed.append(child)
        }

        if !report.removed.isEmpty || !report.failed.isEmpty {
            history.append(HistoryEntry(
                source: source, mode: mode,
                paths: report.removed.map(\.path),
                bytes: report.bytes,
                failures: report.failed.map { "\($0.url.path): \($0.reason)" }
            ))
        }
        return report
    }

    /// Esvazia ~/.Trash (permanente por natureza). Os itens passam pelo guarda um a um.
    public static func emptyTrash(source: String = "Lixeira") async -> RemovalReport {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: Paths.trash, includingPropertiesForKeys: nil, options: [])) ?? []
        let items = contents.map { RemovalItem(url: $0, size: FileSizer.allocatedSize(of: $0)) }
        return await remove(items, mode: .permanent, source: source)
    }

    // MARK: - Interno

    enum Outcome { case success, failure(String) }

    static func removeOne(_ item: RemovalItem, mode: RemovalMode) async -> Outcome {
        let url = item.url
        if case .blocked(let reason) = SafetyGuard.check(url) { return .failure("Bloqueado: \(reason)") }
        guard FileSizer.exists(url) else { return .success }   // já não existe: objetivo cumprido
        if Exclusions.isExcluded(url) { return .failure("Está na lista de pastas ignoradas") }

        let fm = FileManager.default
        do {
            switch mode {
            case .trash:
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch where url.path.hasPrefix("/Applications/") {
                    // Apps instalados pelo administrador: o Finder pede a senha.
                    _ = try await NSWorkspace.shared.recycle([url])
                }
            case .permanent:
                try fm.removeItem(at: url)
            }
            return .success
        } catch {
            return .failure(describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "Sem permissão"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "Não existe mais"
            case NSFileWriteVolumeReadOnlyError: return "Volume somente leitura"
            case NSUserCancelledError: return "Cancelado"
            default: break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            switch Int32(underlying.code) {
            case EPERM, EACCES: return "Sem permissão (pode estar em uso ou protegido pelo macOS)"
            case EBUSY: return "Em uso"
            default: break
            }
        }
        return ns.localizedDescription
    }

    /// Remove da lista itens que estão dentro de outra pasta da mesma lista.
    static func dedupedByAncestor(_ items: [RemovalItem]) -> [RemovalItem] {
        let sorted = items.sorted { $0.url.path.count < $1.url.path.count }
        var kept: [RemovalItem] = []
        var keptPaths: [String] = []
        var seen = Set<String>()
        for item in sorted {
            let path = item.url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if keptPaths.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            kept.append(item)
            keptPaths.append(path)
        }
        return kept
    }
}
