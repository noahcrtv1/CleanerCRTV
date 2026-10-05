import Foundation

/// Um arquivo (ou pacote de documento) grande encontrado pela varredura.
public struct LargeOldFile: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    /// Pasta onde está (caminho completo), pré-calculada para ordenar rápido.
    public let folder: String
    /// Tamanho alocado em disco (placeholders do iCloud contam ~0).
    public let size: Int64
    public let kind: LargeOldKind
    /// Última abertura (Spotlight) ou, sem ela, a data mais recente entre modificação e acesso.
    public let lastUsed: Date
    public let modified: Date?
    /// Pasta que o Finder mostra como arquivo (.pages, .sparsebundle…).
    public let isPackage: Bool
    /// `lastUsed` veio do Spotlight ("Aberto em" do Finder).
    public let lastUsedFromSpotlight: Bool

    public init(url: URL, size: Int64, kind: LargeOldKind, lastUsed: Date, modified: Date? = nil,
                isPackage: Bool = false, lastUsedFromSpotlight: Bool = false) {
        self.url = url
        self.name = url.lastPathComponent
        self.folder = url.deletingLastPathComponent().path
        self.size = size
        self.kind = kind
        self.lastUsed = lastUsed
        self.modified = modified
        self.isPackage = isPackage
        self.lastUsedFromSpotlight = lastUsedFromSpotlight
    }

    /// Para ordenar a coluna "Tipo" pelo nome exibido.
    public var kindTitle: String { kind.singularTitle }

    // Identidade pelo caminho: deixa Set/diff baratos com dezenas de milhares de linhas.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Tamanho mínimo (base 1000, como o Finder).
public enum LargeOldSizeThreshold: Int64, CaseIterable, Sendable, Identifiable {
    case mb10 = 10_000_000
    case mb50 = 50_000_000
    case mb100 = 100_000_000
    case mb500 = 500_000_000
    case gb1 = 1_000_000_000

    public static let `default` = LargeOldSizeThreshold.mb50

    public var id: Int64 { rawValue }
    public var bytes: Int64 { rawValue }

    public var title: String {
        switch self {
        case .mb10: "10 MB"
        case .mb50: "50 MB"
        case .mb100: "100 MB"
        case .mb500: "500 MB"
        case .gb1: "1 GB"
        }
    }
}

/// Há quanto tempo o arquivo não é usado.
public enum LargeOldAge: String, CaseIterable, Sendable, Identifiable {
    case any, month1, month6, year1

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: "Qualquer"
        case .month1: "+1 mês"
        case .month6: "+6 meses"
        case .year1: "+1 ano"
        }
    }

    /// Último uso precisa ser anterior a esta data. nil = qualquer data serve.
    public func cutoff(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .any: nil
        case .month1: calendar.date(byAdding: .month, value: -1, to: now)
        case .month6: calendar.date(byAdding: .month, value: -6, to: now)
        case .year1: calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}

public struct LargeOldKindTotal: Sendable, Equatable {
    public var count = 0
    public var bytes: Int64 = 0

    public init(count: Int = 0, bytes: Int64 = 0) {
        self.count = count
        self.bytes = bytes
    }
}

/// Filtros da tela. `kinds` vazio = todos os tipos.
public struct LargeOldFilter: Sendable, Equatable {
    public var minSize: Int64
    public var age: LargeOldAge
    public var kinds: Set<LargeOldKind>

    public init(minSize: Int64 = LargeOldSizeThreshold.default.bytes, age: LargeOldAge = .any, kinds: Set<LargeOldKind> = []) {
        self.minSize = minSize
        self.age = age
        self.kinds = kinds
    }

    /// Critério do Painel: 50 MB ou mais, sem uso há 6 meses ou mais.
    public static let dashboard = LargeOldFilter(minSize: LargeOldSizeThreshold.mb50.bytes, age: .month6)

    /// Só tamanho e idade (os totais por tipo dos filtros usam isto).
    public func matchesSizeAndAge(_ file: LargeOldFile, cutoff: Date?) -> Bool {
        guard file.size >= minSize else { return false }
        if let cutoff, file.lastUsed > cutoff { return false }
        return true
    }

    public func matches(_ file: LargeOldFile, cutoff: Date?) -> Bool {
        matchesSizeAndAge(file, cutoff: cutoff) && (kinds.isEmpty || kinds.contains(file.kind))
    }

    public func apply(to files: [LargeOldFile], now: Date = Date()) -> [LargeOldFile] {
        let cutoff = age.cutoff(from: now)
        return files.filter { matches($0, cutoff: cutoff) }
    }

    /// Totais por tipo considerando só tamanho e idade.
    public func totalsByKind(_ files: [LargeOldFile], now: Date = Date()) -> [LargeOldKind: LargeOldKindTotal] {
        let cutoff = age.cutoff(from: now)
        var totals: [LargeOldKind: LargeOldKindTotal] = [:]
        for file in files where matchesSizeAndAge(file, cutoff: cutoff) {
            totals[file.kind, default: LargeOldKindTotal()].count += 1
            totals[file.kind, default: LargeOldKindTotal()].bytes += file.size
        }
        return totals
    }
}
