import Foundation

/// Item "Abrir ao iniciar sessão" (lista legada, lida pelo Eventos do Sistema).
public struct OptimizeLoginItem: Sendable, Hashable, Identifiable {
    public var id: String { (path ?? "") + "|" + name }
    public let name: String
    public let path: String?
    public let isHidden: Bool

    public init(name: String, path: String?, isHidden: Bool) {
        self.name = name
        self.path = path
        self.isHidden = isHidden
    }

    public var url: URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}

public enum OptimizeLoginItemsError: Error, Sendable, Equatable {
    case notPermitted
    case cancelled
    case timeout
    case failed(String)

    init(_ error: OptimizeScriptError) {
        if error.isNotPermitted { self = .notPermitted }
        else if error.isUserCancelled { self = .cancelled }
        else if error.isTimeout { self = .timeout }
        else { self = .failed(error.message) }
    }

    public var title: String {
        switch self {
        case .notPermitted: "Sem permissão para os Eventos do Sistema"
        case .cancelled: "Pedido cancelado"
        case .timeout: "O Eventos do Sistema não respondeu"
        case .failed: "Não deu para ler os itens de início"
        }
    }

    public var message: String {
        switch self {
        case .notPermitted:
            "Abra Ajustes ▸ Privacidade e Segurança ▸ Automação e ative “Eventos do Sistema” para o CleanerCRTV. Depois, tente de novo."
        case .cancelled:
            "Você recusou o pedido do macOS. Dá para tentar de novo quando quiser."
        case .timeout:
            "Pode ser que o pedido de permissão tenha ficado aberto sem resposta. Tente de novo."
        case .failed(let reason):
            reason
        }
    }
}

/// O macOS não deixa um app comum listar todos os itens em segundo plano (BTM). Aqui só entra a lista
/// "Abrir ao iniciar sessão", via Eventos do Sistema — o macOS pede a permissão de Automação na 1ª vez.
public enum OptimizeLoginItems {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    public static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static let listSource = """
    tell application "System Events" to get {name, path, hidden} of every login item
    """

    static let removeSource = """
    on removeLoginItem(itemName, itemPath)
        tell application "System Events"
            if itemPath is not "" then
                delete (every login item whose path is itemPath)
            else
                delete (every login item whose name is itemName)
            end if
        end tell
        return true
    end removeLoginItem
    """

    public static func list() async -> Result<[OptimizeLoginItem], OptimizeLoginItemsError> {
        let result = await OptimizeAppleScript.run(listSource) { descriptor in
            let columns = columns(from: descriptor)
            return items(names: columns.names, paths: columns.paths, hidden: columns.hidden)
        }
        return result.mapError(OptimizeLoginItemsError.init)
    }

    /// Tira o item da lista de início (o app em si não é tocado).
    public static func remove(_ item: OptimizeLoginItem) async -> Result<Void, OptimizeLoginItemsError> {
        let result = await OptimizeAppleScript.call(removeSource, handler: "removeLoginItem",
                                                    arguments: [item.name, item.path ?? ""]) { _ in () }
        return result.mapError(OptimizeLoginItemsError.init)
    }

    // MARK: - Conversão

    /// Resultado de `{name, path, hidden}`: três listas paralelas (path pode vir `missing value`).
    static func columns(from descriptor: NSAppleEventDescriptor) -> (names: [String], paths: [String?], hidden: [Bool]) {
        guard descriptor.numberOfItems >= 3 else { return ([], [], []) }
        func list(_ index: Int) -> [NSAppleEventDescriptor] {
            guard let column = descriptor.atIndex(index), column.numberOfItems > 0 else { return [] }
            return (1...column.numberOfItems).compactMap { column.atIndex($0) }
        }
        // `missing value` chega como typeType com o código 'msng' (não como descritor 'msng').
        let missing = OptimizeAppleScript.fourCharCode("msng")
        let typeType = OptimizeAppleScript.fourCharCode("type")
        func isMissing(_ d: NSAppleEventDescriptor) -> Bool {
            d.descriptorType == missing || (d.descriptorType == typeType && d.typeCodeValue == missing)
        }
        let names = list(1).map { $0.stringValue ?? "" }
        let paths = list(2).map { isMissing($0) ? nil : $0.stringValue }
        let hidden = list(3).map { $0.booleanValue }
        return (names, paths, hidden)
    }

    static func items(names: [String], paths: [String?], hidden: [Bool]) -> [OptimizeLoginItem] {
        var seen: Set<OptimizeLoginItem.ID> = []
        return names.enumerated().compactMap { index, name in
            let path = index < paths.count ? paths[index].flatMap { $0.isEmpty ? nil : $0 } : nil
            let label = name.isEmpty ? (path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "") : name
            guard !label.isEmpty else { return nil }
            let item = OptimizeLoginItem(name: label, path: path, isHidden: index < hidden.count ? hidden[index] : false)
            // O mesmo app registrado duas vezes vira uma linha só (a remoção tira todas as cópias).
            return seen.insert(item.id).inserted ? item : nil
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
