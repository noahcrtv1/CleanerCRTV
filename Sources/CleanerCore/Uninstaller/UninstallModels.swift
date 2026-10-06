import Foundation

/// Um app instalado (pacote .app) e o que se sabe dele.
public struct UninstallApp: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    /// Nome como o Finder mostra.
    public let name: String
    public let bundleID: String?
    public let version: String?
    /// Equipe do desenvolvedor na assinatura (nil se sem assinatura ou ad-hoc).
    public let teamID: String?
    /// Tamanho alocado. nil enquanto não foi medido.
    public var size: Int64?
    /// Último uso segundo o Spotlight. nil = desconhecido.
    public let lastUsed: Date?
    public let isAppStore: Bool
    public let isApple: Bool
    public let isSelf: Bool
    /// Identificadores de ajudantes, extensões e itens de início que vêm dentro do pacote.
    public let embeddedBundleIDs: [String]
    /// Outros nomes do app (CFBundleName, nome do arquivo…), para achar pastas com o nome dele.
    public let aliases: [String]
    /// Contêineres de grupo que a assinatura do app (ou de extensões dele) declara, em minúsculas.
    public let appGroups: [String]
    /// Muda quando o pacote é trocado (atualização); serve para reaproveitar o tamanho medido.
    public let stamp: String
    /// Motivo para não poder ser removido. nil = pode.
    public let blockReason: String?

    public init(url: URL, name: String, bundleID: String?, version: String? = nil, teamID: String? = nil,
                size: Int64? = nil, lastUsed: Date? = nil, isAppStore: Bool = false, isApple: Bool = false,
                isSelf: Bool = false, embeddedBundleIDs: [String] = [], aliases: [String] = [],
                appGroups: [String] = [], stamp: String = "", blockReason: String? = nil) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.teamID = teamID
        self.size = size
        self.lastUsed = lastUsed
        self.isAppStore = isAppStore
        self.isApple = isApple
        self.isSelf = isSelf
        self.embeddedBundleIDs = embeddedBundleIDs
        self.aliases = aliases
        self.appGroups = Array(Set(appGroups.map { $0.lowercased() })).sorted()
        self.stamp = stamp
        self.blockReason = blockReason
    }

    public var canUninstall: Bool { blockReason == nil }

    /// Sem uso desde `date` (só quando o último uso é conhecido).
    public func isUnused(since date: Date) -> Bool {
        guard let lastUsed else { return false }
        return lastUsed < date
    }

    /// Identificador principal + os de dentro do pacote, em minúsculas.
    public var allIDs: [String] {
        var ids: [String] = []
        if let bundleID { ids.append(bundleID.lowercased()) }
        ids.append(contentsOf: embeddedBundleIDs.map { $0.lowercased() })
        return Array(Set(ids)).sorted()
    }

    /// Identificadores que contam como "deste app" ao procurar restos: o principal e os embutidos
    /// do mesmo fabricante (um Sparkle embutido não faz os caches do Sparkle virarem deste app).
    public var matchIDs: [String] {
        guard let main = bundleID?.lowercased() else { return [] }
        let vendor = UninstallBundleID.vendor(of: main)
        let embedded = embeddedBundleIDs.map { $0.lowercased() }.filter {
            UninstallBundleID.looksLikeBundleID($0) && UninstallBundleID.vendor(of: $0) == vendor && !UninstallBundleID.isShared($0)
        }
        return Array(Set([main] + embedded)).sorted()
    }

    /// Nomes que valem para casar com o nome exato de uma pasta (minúsculas, sem genéricos).
    public var matchNames: [String] {
        let all = ([name] + aliases).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return Array(Set(all.filter { $0.count >= 3 && !$0.contains("/") && !UninstallBundleID.genericNames.contains($0) })).sorted()
    }
}

/// Grau de certeza de que um resto é do app.
public enum UninstallConfidence: String, Sendable, Hashable, Codable {
    /// Identificador do app idêntico (ou de um ajudante dele).
    case high
    /// Nome da pasta igual ao nome do app, ou resto de app que já não está instalado.
    case medium

    public var label: String {
        switch self {
        case .high: "alta"
        case .medium: "média"
        }
    }
}

/// Tipo de resto, para agrupar na lista.
public enum UninstallLeftoverKind: String, Sendable, Hashable, CaseIterable, Codable {
    case preferences, caches, support, container, groupContainer, savedState, webData, logs, launchAgent, scripts

    public var label: String {
        switch self {
        case .preferences: "Preferências"
        case .caches: "Caches"
        case .support: "Suporte"
        case .container: "Contêiner"
        case .groupContainer: "Contêiner de grupo"
        case .savedState: "Estado salvo"
        case .webData: "Dados da web"
        case .logs: "Registros"
        case .launchAgent: "Agente de início"
        case .scripts: "Scripts"
        }
    }

    public var symbol: String {
        switch self {
        case .preferences: "gearshape"
        case .caches: "archivebox"
        case .support: "folder"
        case .container: "shippingbox"
        case .groupContainer: "square.stack.3d.up"
        case .savedState: "macwindow"
        case .webData: "globe"
        case .logs: "doc.text"
        case .launchAgent: "power"
        case .scripts: "applescript"
        }
    }

    /// Pode guardar documentos, bancos de dados ou downloads criados no app: nunca vem marcado.
    /// Application Scripts guarda scripts que o próprio usuário instalou para o app.
    public var mayHoldUserData: Bool {
        switch self {
        case .support, .container, .groupContainer, .scripts: true
        default: false
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Arquivo ou pasta deixado por um app em ~/Library.
public struct UninstallLeftover: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let kind: UninstallLeftoverKind
    public let confidence: UninstallConfidence
    /// Identificador a que o item pertence (minúsculas). Para restos achados pelo nome, o do app.
    public let ownerKey: String
    public var size: Int64
    /// Modificação mais recente (o próprio item ou qualquer coisa dentro dele).
    public var modified: Date?

    public init(url: URL, kind: UninstallLeftoverKind, confidence: UninstallConfidence, ownerKey: String,
                size: Int64 = 0, modified: Date? = nil) {
        self.url = url
        self.kind = kind
        self.confidence = confidence
        self.ownerKey = ownerKey
        self.size = size
        self.modified = modified
    }

    /// Só o que é certeiro e regenerável vem marcado ao desinstalar.
    public var isSelectedByDefault: Bool { confidence == .high && !kind.mayHoldUserData }
}

/// Restos agrupados por tipo (para a lista de um app).
public struct UninstallLeftoverGroup: Sendable, Identifiable, Hashable {
    public var id: UninstallLeftoverKind { kind }
    public let kind: UninstallLeftoverKind
    public var items: [UninstallLeftover]
    public var size: Int64 { items.reduce(0) { $0 + $1.size } }

    public static func grouped(_ items: [UninstallLeftover]) -> [UninstallLeftoverGroup] {
        Dictionary(grouping: items, by: \.kind)
            .map { UninstallLeftoverGroup(kind: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.kind.order < $1.kind.order }
    }
}

/// Restos de um app que já não está instalado, juntos pelo identificador.
public struct UninstallOrphanGroup: Sendable, Identifiable, Hashable {
    public var id: String { key }
    public let key: String
    public var items: [UninstallLeftover]

    public init(key: String, items: [UninstallLeftover]) {
        self.key = key
        self.items = items
    }

    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
    public var newest: Date? { items.compactMap(\.modified).max() }
    public var kinds: [UninstallLeftoverKind] { Array(Set(items.map(\.kind))).sorted { $0.order < $1.order } }
}

/// O que uma varredura pode oferecer: respeita o `SafetyGuard` e as pastas ignoradas.
public struct UninstallFilter: Sendable {
    let excluded: [String]
    /// Só os testes desligam (as árvores falsas ficam fora das áreas permitidas).
    let checksSafety: Bool

    init(excluded: [String] = [], checksSafety: Bool = true) {
        self.excluded = excluded.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.checksSafety = checksSafety
    }

    /// Regras de agora (lê as pastas ignoradas uma vez).
    public static func live() -> UninstallFilter { UninstallFilter(excluded: Exclusions.paths) }

    public func isExcluded(_ url: URL) -> Bool {
        Exclusions.isExcluded(path: url.standardizedFileURL.path, in: excluded)
    }

    public func allows(_ url: URL) -> Bool {
        if isExcluded(url) { return false }
        return !checksSafety || SafetyGuard.check(url).isAllowed
    }
}
