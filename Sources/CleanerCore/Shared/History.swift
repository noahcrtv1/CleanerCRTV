import Foundation

public struct HistoryEntry: Codable, Identifiable, Sendable, Hashable {
    public var id = UUID()
    public var date = Date()
    /// Módulo que pediu (ex.: "Lixo do sistema", "Desinstalador").
    public var source: String
    public var mode: RemovalMode
    /// Até 1000 caminhos (o resto só entra na contagem).
    public var paths: [String]
    public var itemCount: Int
    public var bytes: Int64
    public var failures: [String]

    public init(source: String, mode: RemovalMode, paths: [String], bytes: Int64, failures: [String]) {
        self.source = source
        self.mode = mode
        self.paths = Array(paths.prefix(1000))
        self.itemCount = paths.count
        self.bytes = bytes
        self.failures = Array(failures.prefix(200))
    }
}

/// Histórico de limpezas em ~/Library/Application Support/CleanerCRTV/history.json.
public final class HistoryStore: @unchecked Sendable {
    public static let shared = HistoryStore()
    public static let didChange = Notification.Name("CleanerCRTV.historyDidChange")

    private let queue = DispatchQueue(label: "CleanerCRTV.history")
    private let url: URL

    public init(url: URL = Paths.appSupport.appendingPathComponent("history.json")) {
        self.url = url
    }

    public func load() -> [HistoryEntry] {
        queue.sync { read() }
    }

    public func append(_ entry: HistoryEntry) {
        queue.sync {
            var entries = read()
            entries.insert(entry, at: 0)
            write(Array(entries.prefix(500)))
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func clear() {
        queue.sync { write([]) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Total liberado (só modo permanente) e movido para a Lixeira, desde sempre.
    public func totals() -> (permanent: Int64, trashed: Int64) {
        let entries = load()
        return (entries.filter { $0.mode == .permanent }.reduce(0) { $0 + $1.bytes },
                entries.filter { $0.mode == .trash }.reduce(0) { $0 + $1.bytes })
    }

    private func read() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func write(_ entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
