import Foundation

/// Pastas de ~/Library onde os apps deixam dados.
public enum UninstallLocation: String, Sendable, Hashable, CaseIterable {
    case applicationSupport, caches, preferences, byHost, containers, groupContainers, savedState
    case httpStorages, webKit, cookies, logs, launchAgents, applicationScripts

    public var relativePath: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .byHost: "Preferences/ByHost"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .savedState: "Saved Application State"
        case .httpStorages: "HTTPStorages"
        case .webKit: "WebKit"
        case .cookies: "Cookies"
        case .logs: "Logs"
        case .launchAgents: "LaunchAgents"
        case .applicationScripts: "Application Scripts"
        }
    }

    public var kind: UninstallLeftoverKind {
        switch self {
        case .applicationSupport: .support
        case .caches: .caches
        case .preferences, .byHost: .preferences
        case .containers: .container
        case .groupContainers: .groupContainer
        case .savedState: .savedState
        case .httpStorages, .webKit, .cookies: .webData
        case .logs: .logs
        case .launchAgents: .launchAgent
        case .applicationScripts: .scripts
        }
    }

    /// Onde uma pasta com o nome exato do app ainda é indício (de confiança média).
    var allowsNameMatch: Bool {
        switch self {
        case .applicationSupport, .caches, .logs: true
        default: false
        }
    }

    /// Onde os nomes podem vir como "group.<id>" ou "<TEAMID>.<id>".
    var allowsGroupPrefix: Bool { self == .groupContainers || self == .applicationScripts }
}

/// Um item de primeiro nível numa das pastas de ~/Library.
public struct UninstallLibraryEntry: Sendable, Hashable {
    public struct Agent: Sendable, Hashable {
        public var label: String?
        /// Program ou o primeiro de ProgramArguments.
        public var program: String?
        public var arguments: [String]
        public var programExists: Bool

        public init(label: String?, program: String?, arguments: [String] = [], programExists: Bool) {
            self.label = label
            self.program = program
            self.arguments = arguments
            self.programExists = programExists
        }
    }

    public let url: URL
    public let location: UninstallLocation
    public let modified: Date?
    /// Identificador tirado do nome, em minúsculas (sem .plist, .savedState, "group."…). nil se o nome não serve.
    public let key: String?
    /// Mesmo identificador com as maiúsculas originais (para perguntar ao LaunchServices).
    public let rawKey: String?
    /// Prefixo de equipe em "ABCDE12345.com.foo" (Contêineres de grupo).
    public let teamPrefix: String?
    /// Só em LaunchAgents.
    public let agent: Agent?

    public var name: String { url.lastPathComponent }

    public init(url: URL, location: UninstallLocation, modified: Date? = nil, agent: Agent? = nil) {
        self.url = url
        self.location = location
        self.modified = modified
        self.agent = agent
        let parsed = Self.parseKey(name: url.lastPathComponent, location: location)
        rawKey = parsed?.key
        key = parsed?.key.lowercased()
        teamPrefix = parsed?.team
    }

    /// Tira do nome o que não faz parte do identificador, conforme a pasta.
    static func parseKey(name: String, location: UninstallLocation) -> (key: String, team: String?)? {
        var base = name
        func dropSuffix(_ suffix: String, required: Bool) -> Bool {
            if base.lowercased().hasSuffix(suffix) {
                base = String(base.dropLast(suffix.count))
                return true
            }
            return !required
        }
        switch location {
        case .preferences, .launchAgents:
            guard dropSuffix(".plist", required: true) else { return nil }
        case .byHost:
            guard dropSuffix(".plist", required: true) else { return nil }
            // com.foo.app.<UUID do Mac>.plist
            var parts = base.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count > 1, let last = parts.last, isHostSuffix(last) { parts.removeLast() }
            base = parts.joined(separator: ".")
        case .savedState:
            guard dropSuffix(".savedstate", required: true) else { return nil }
        case .cookies:
            guard dropSuffix(".binarycookies", required: true) else { return nil }
        case .httpStorages:
            _ = dropSuffix(".binarycookies", required: false)
        default:
            break
        }
        var team: String?
        if location.allowsGroupPrefix {
            if base.lowercased().hasPrefix("group.") {
                base = String(base.dropFirst("group.".count))
            } else if let dot = base.firstIndex(of: "."), isTeamID(base[..<dot]) {
                team = String(base[..<dot])
                base = String(base[base.index(after: dot)...])
            }
        }
        guard !base.isEmpty else { return nil }
        return (base, team)
    }

    /// Equipe da Apple: 10 letras maiúsculas/dígitos.
    static func isTeamID(_ s: Substring) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// UUID ou endereço de hardware no fim dos arquivos de ByHost.
    static func isHostSuffix(_ s: Substring) -> Bool {
        s.count >= 12 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

/// Retrato de primeiro nível das pastas de ~/Library que interessam. Sem descer em nada.
public struct UninstallLibraryIndex: Sendable {
    public let library: URL
    public let entries: [UninstallLibraryEntry]

    public init(library: URL, entries: [UninstallLibraryEntry]) {
        self.library = library
        self.entries = entries
    }

    public static func build(home: URL) -> UninstallLibraryIndex {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let fm = FileManager.default
        var entries: [UninstallLibraryEntry] = []
        for location in UninstallLocation.allCases {
            let folder = library.appendingPathComponent(location.relativePath, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for url in items {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let agent = location == .launchAgents ? readAgent(url) : nil
                entries.append(UninstallLibraryEntry(url: url, location: location, modified: modified, agent: agent))
            }
        }
        return UninstallLibraryIndex(library: library, entries: entries)
    }

    static func readAgent(_ url: URL) -> UninstallLibraryEntry.Agent? {
        guard url.pathExtension.lowercased() == "plist",
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let arguments = (plist["ProgramArguments"] as? [String]) ?? []
        let program = (plist["Program"] as? String) ?? arguments.first
        // Caminho relativo (resolvido pelo launchd): na dúvida, conta como existente.
        let exists = program.map { !$0.hasPrefix("/") || FileManager.default.fileExists(atPath: $0) } ?? false
        return .init(label: plist["Label"] as? String, program: program, arguments: arguments, programExists: exists)
    }
}
