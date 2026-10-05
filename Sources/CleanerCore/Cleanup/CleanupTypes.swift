import Foundation

/// Categorias do "Lixo do sistema" (a ordem dos casos é a ordem de exibição).
public enum CleanupCategoryID: String, CaseIterable, Sendable, Hashable, Codable {
    case appCaches, containerCaches, browsers, developer, logs, mailAttachments
    case savedState, installers, iosBackups, trash
}

/// Uma categoria com explicação, ícone e as regras que dizem onde procurar.
public struct CleanupCategory: Sendable, Identifiable {
    public let id: CleanupCategoryID
    public let title: String
    public let explanation: String
    /// SF Symbol.
    public let symbol: String
    /// Itens entram marcados por padrão (respeitando app aberto, regra opcional etc.).
    public let isRecommended: Bool
    /// Menor reivindica primeiro: categorias específicas antes das genéricas, para nenhum item sair duas vezes.
    public let claimOrder: Int
    public let rules: [CleanupRule]

    public init(id: CleanupCategoryID, title: String, explanation: String, symbol: String,
                isRecommended: Bool, claimOrder: Int, rules: [CleanupRule]) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.symbol = symbol
        self.isRecommended = isRecommended
        self.claimOrder = claimOrder
        self.rules = rules
    }

    /// A Lixeira aparece na lista mas tem ação própria (esvaziar), fora do "Limpar".
    public var isTrash: Bool { id == .trash }
}

/// Onde procurar. `pattern` é relativo à pasta pessoal; um componente `*` casa com qualquer subpasta
/// (ex.: `Library/Containers/*/Data/Library/Caches`).
public struct CleanupRule: Sendable {
    public enum Mode: Sendable {
        /// O próprio caminho é um item.
        case itself
        /// Cada filho do caminho é um item.
        case children
    }

    public var pattern: String
    public var mode: Mode
    /// Dentro de uma categoria recomendada, a regra pode ser opcional (ex.: Arquivos do Xcode).
    public var isRecommended = true
    /// Ler contêineres de outros apps sem Acesso Total ao Disco dispara um aviso do macOS: sem o acesso, a regra é pulada.
    public var needsFullDiskAccess = false
    public var owner: CleanupOwner = .none
    public var label: CleanupLabelStyle = .name
    public var filter = CleanupFilter()
    /// Aviso curto por item (ex.: "Necessário para simbolizar falhas").
    public var note: String?
    /// Se um item contém caminhos já reivindicados por outra regra (ou ignorados), lista os filhos dele no lugar.
    public var splitsAroundClaims = false
    /// Arquivos alterados há menos que isso são pulados; pastas com conteúdo recente entram desmarcadas ("Em uso").
    public var activeWindow: TimeInterval?

    public init(_ pattern: String, _ mode: Mode, isRecommended: Bool = true, needsFullDiskAccess: Bool = false,
                owner: CleanupOwner = .none, label: CleanupLabelStyle = .name, filter: CleanupFilter = CleanupFilter(),
                note: String? = nil, splitsAroundClaims: Bool = false, activeWindow: TimeInterval? = nil) {
        self.pattern = pattern
        self.mode = mode
        self.isRecommended = isRecommended
        self.needsFullDiskAccess = needsFullDiskAccess
        self.owner = owner
        self.label = label
        self.filter = filter
        self.note = note
        self.splitsAroundClaims = splitsAroundClaims
        self.activeWindow = activeWindow
    }
}

/// De quem é o item (para o rótulo, o ícone e a regra do "App aberto").
public enum CleanupOwner: Sendable {
    case none
    /// Bundle IDs fixos. Terminar com `.*` casa com o prefixo (ex.: `com.jetbrains.*`).
    case fixed([String])
    /// O nome do item é o bundle ID (ex.: `~/Library/Caches/com.spotify.client`, `….savedState`).
    case itemName
    /// O valor do primeiro `*` do padrão é o bundle ID (contêineres).
    case wildcard
}

public enum CleanupLabelStyle: Sendable {
    /// Nome do arquivo.
    case name
    /// Nome do app dono (cai para o nome do item).
    case app
    /// Nome fixo; `detail` opcional (nil = caminho relativo, quando houver).
    case fixed(String, detail: String? = nil)
    /// Navegador: nome fixo + subpasta de cache e perfil.
    case browser(String)
    case derivedData
    case xcodeArchive
    /// Plataforma (iOS, watchOS…) + versão lida do nome da pasta.
    case deviceSupport(String)
    case iosBackup
}

public struct CleanupFilter: Sendable {
    public enum Kind: Sendable { case any, files, directories }

    public var kind: Kind = .any
    /// Extensões aceitas, em minúsculas (nil = todas).
    public var extensions: Set<String>?
    /// Nomes recusados, em minúsculas.
    public var excludedNames: Set<String> = []
    /// Prefixos de nome recusados, em minúsculas.
    public var excludedPrefixes: [String] = []
    /// Só itens sem mudança há pelo menos isso (data mais recente entre modificação e chegada na pasta).
    public var minAge: TimeInterval?
    /// Itens ocultos (nome com ponto) entram? `.DS_Store` nunca entra.
    public var includeHidden = false
    /// Mantém a versão mais nova (Suporte a dispositivos do Xcode): só as antigas viram itens.
    public var keepNewestVersion = false
    /// Filtra os valores do `*` (ex.: contêineres de serviços da Apple ficam de fora).
    public var wildcardAccepts: (@Sendable (String) -> Bool)?

    public init(kind: Kind = .any, extensions: Set<String>? = nil, excludedNames: Set<String> = [],
                excludedPrefixes: [String] = [], minAge: TimeInterval? = nil, includeHidden: Bool = false,
                keepNewestVersion: Bool = false, wildcardAccepts: (@Sendable (String) -> Bool)? = nil) {
        self.kind = kind
        self.extensions = extensions
        self.excludedNames = excludedNames
        self.excludedPrefixes = excludedPrefixes
        self.minAge = minAge
        self.includeHidden = includeHidden
        self.keepNewestVersion = keepNewestVersion
        self.wildcardAccepts = wildcardAccepts
    }
}

/// Um item encontrado.
public struct CleanupEntry: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public let url: URL
    /// Tamanho em disco (blocos alocados).
    public let size: Int64
    public let category: CleanupCategoryID
    /// Nome amigável (ex.: nome do app).
    public let label: String
    /// Complemento (perfil, subpasta, data do backup…).
    public let detail: String?
    public let bundleID: String?
    /// App dono, para mostrar o ícone dele.
    public let appURL: URL?
    public let isAppRunning: Bool
    /// Conteúdo gravado há instantes.
    public let isActive: Bool
    public let lastModified: Date?
    /// Entra marcado por padrão.
    public let isRecommended: Bool
    public let note: String?

    public init(url: URL, size: Int64, category: CleanupCategoryID, label: String, detail: String? = nil,
                bundleID: String? = nil, appURL: URL? = nil, isAppRunning: Bool = false, isActive: Bool = false,
                lastModified: Date? = nil, isRecommended: Bool, note: String? = nil) {
        self.url = url
        self.size = size
        self.category = category
        self.label = label
        self.detail = detail
        self.bundleID = bundleID
        self.appURL = appURL
        self.isAppRunning = isAppRunning
        self.isActive = isActive
        self.lastModified = lastModified
        self.isRecommended = isRecommended
        self.note = note
    }

    public var removalItem: RemovalItem {
        RemovalItem(url: url, size: size, label: detail.map { "\(label) · \($0)" } ?? label)
    }
}

public struct CleanupScanProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case discovering, measuring }

    public var stage: Stage
    /// Caminho sendo lido agora (só informativo).
    public var currentPath: String?
    public var measured: Int
    public var total: Int
    public var foundCount: Int
    public var foundBytes: Int64

    /// nil enquanto procura (indeterminado).
    public var fraction: Double? {
        stage == .measuring && total > 0 ? Double(measured) / Double(total) : nil
    }
}

public struct CleanupScanResult: Sendable {
    public var entries: [CleanupEntry]
    /// Pastas que não puderam ser lidas (sem Acesso Total ao Disco) ou foram puladas por falta dele.
    public var inaccessiblePaths: [String]
    public var wasCancelled: Bool

    public var inaccessibleCount: Int { inaccessiblePaths.count }

    public init(entries: [CleanupEntry] = [], inaccessiblePaths: [String] = [], wasCancelled: Bool = false) {
        self.entries = entries
        self.inaccessiblePaths = inaccessiblePaths
        self.wasCancelled = wasCancelled
    }
}
