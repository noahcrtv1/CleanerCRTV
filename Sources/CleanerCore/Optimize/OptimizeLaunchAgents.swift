import AppKit
import Darwin
import Foundation

/// Onde o .plist mora (define quem pode mexer).
public enum OptimizeAgentScope: String, Sendable, CaseIterable, Hashable {
    /// ~/Library/LaunchAgents — do usuário, gerenciável pelo app.
    case user
    /// /Library/LaunchAgents — rodam para todos os usuários; só leitura aqui.
    case systemAgent
    /// /Library/LaunchDaemons — rodam como root; só leitura aqui.
    case systemDaemon

    public var isManageable: Bool { self == .user }

    public var directory: URL {
        switch self {
        case .user: Paths.library("LaunchAgents")
        case .systemAgent: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
        case .systemDaemon: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        }
    }

    public var title: String {
        switch self {
        case .user: "Seus agentes"
        case .systemAgent: "Agentes de todos os usuários"
        case .systemDaemon: "Daemons do sistema"
        }
    }
}

public enum OptimizeKeepAlive: Sendable, Hashable {
    case no, always, conditional
}

/// Um horário de `StartCalendarInterval` (campos ausentes = "qualquer").
public struct OptimizeCalendarInterval: Sendable, Hashable {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    public var weekday: Int?
    public var month: Int?

    public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }
}

public enum OptimizeAgentProblem: Sendable, Hashable {
    /// O programa apontado não existe mais (app removido, Homebrew desinstalado…).
    case missingProgram(String)
    /// Arquivo que o launchd não consegue usar (plist corrompido ou sem Label).
    case invalidPlist

    public var message: String {
        switch self {
        case .missingProgram: "O programa que ele abre não existe mais"
        case .invalidPlist: "Arquivo .plist inválido: o macOS não consegue usá-lo"
        }
    }
}

/// App dono de um agente (palpite).
public struct OptimizeOwnerApp: Sendable, Hashable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// Um agente ou daemon do launchd, lido do .plist e cruzado com o estado do launchd.
public struct OptimizeLaunchAgent: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let scope: OptimizeAgentScope
    public let label: String
    /// `Program`, ou `ProgramArguments[0]`, ou `BundleProgram`.
    public let program: String?
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: OptimizeKeepAlive
    public let startInterval: Int?
    public let calendarIntervals: [OptimizeCalendarInterval]
    /// WatchPaths / QueueDirectories / StartOnMount.
    public let watchesFiles: Bool
    /// Chave `Disabled` do próprio .plist (legado; o launchctl tem a palavra final).
    public let disabledInPlist: Bool
    public let associatedBundleIDs: [String]
    public let problem: OptimizeAgentProblem?

    // Estado do launchd
    public var isLoaded = false
    public var pid: Int?
    public var lastExitStatus: Int?
    /// `launchctl print-disabled`: nil = sem decisão registrada.
    public var disabledOverride: Bool?

    public var owner: OptimizeOwnerApp?
    /// Pode ir para a remoção (agente do usuário e liberado pelo SafetyGuard).
    public var isRemovable = false

    public init(url: URL, scope: OptimizeAgentScope, label: String, program: String? = nil, arguments: [String] = [],
                runAtLoad: Bool = false, keepAlive: OptimizeKeepAlive = .no, startInterval: Int? = nil,
                calendarIntervals: [OptimizeCalendarInterval] = [], watchesFiles: Bool = false,
                disabledInPlist: Bool = false, associatedBundleIDs: [String] = [], problem: OptimizeAgentProblem? = nil) {
        self.url = url
        self.scope = scope
        self.label = label
        self.program = program
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.startInterval = startInterval
        self.calendarIntervals = calendarIntervals
        self.watchesFiles = watchesFiles
        self.disabledInPlist = disabledInPlist
        self.associatedBundleIDs = associatedBundleIDs
        self.problem = problem
    }

    public var isDisabled: Bool { disabledOverride ?? disabledInPlist }
    public var isEnabled: Bool { !isDisabled }
    public var isBroken: Bool { problem != nil }
    public var isRunning: Bool { pid != nil }
    public var isManageable: Bool { scope.isManageable && problem != .invalidPlist && OptimizeLaunchctl.isValidLabel(label) }
    public var displayName: String { owner?.name ?? label }

    /// Caminho absoluto do programa, quando há um.
    public var programURL: URL? {
        guard let program, program.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: program)
    }

    /// Busca por nome, rótulo, programa ou arquivo (sem diferenciar maiúsculas e acentos).
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [displayName, label, program ?? "", url.lastPathComponent].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Quando roda, em português (ex.: "Ao iniciar sessão · Sempre ativo").
    public var scheduleDescription: String {
        var parts: [String] = []
        if runAtLoad { parts.append(scope == .systemDaemon ? "Ao ligar o Mac" : "Ao iniciar sessão") }
        switch keepAlive {
        case .always: parts.append("Sempre ativo")
        case .conditional: parts.append("Mantido ativo")
        case .no: break
        }
        if let startInterval, startInterval > 0 { parts.append(Self.describeInterval(startInterval)) }
        if let calendar = Self.describeCalendar(calendarIntervals) { parts.append(calendar) }
        if watchesFiles, parts.count < 2 { parts.append("Quando arquivos mudam") }
        return parts.isEmpty ? "Sob demanda" : parts.prefix(2).joined(separator: " · ")
    }

    static func describeInterval(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "A cada \(seconds) s"
        case ..<3600: "A cada \(seconds / 60) min"
        case 86_400: "Uma vez por dia"
        case ..<86_400 where seconds % 3600 == 0: "A cada \(seconds / 3600) h"
        case ..<86_400: "A cada \(seconds / 3600) h \(seconds % 3600 / 60) min"
        case _ where seconds % 86_400 == 0: "A cada \(seconds / 86_400) dias"
        default: "A cada \(seconds / 3600) h"
        }
    }

    static func describeCalendar(_ intervals: [OptimizeCalendarInterval]) -> String? {
        guard let first = intervals.first else { return nil }
        guard intervals.count == 1 else { return "Em \(intervals.count) horários programados" }
        let time: String? = first.hour.map { String(format: " às %02ld:%02ld", $0, first.minute ?? 0) }
        if let weekday = first.weekday {
            let names = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"]
            let name = names[((weekday % 7) + 7) % 7]
            let every = (name == "domingo" || name == "sábado") ? "Todo" : "Toda"
            return "\(every) \(name)\(time ?? "")"
        }
        if let day = first.day { return "Todo dia \(day) do mês\(time ?? "")" }
        if let time { return "Todo dia\(time)" }
        if let minute = first.minute { return String(format: "A cada hora, no minuto %02ld", minute) }
        return "A cada minuto"
    }
}

// MARK: - Leitura do .plist

public enum OptimizeLaunchPlist {
    /// Interpreta um .plist do launchd. Nunca falha: conteúdo ilegível vira `.invalidPlist`.
    public static func parse(_ data: Data, url: URL, scope: OptimizeAgentScope,
                             isMissing: (String) -> Bool = pathIsMissing) -> OptimizeLaunchAgent {
        let fallbackLabel = url.deletingPathExtension().lastPathComponent
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any],
              let label = (dict["Label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty
        else {
            return OptimizeLaunchAgent(url: url, scope: scope, label: fallbackLabel, problem: .invalidPlist)
        }

        let arguments = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        let program = nonEmpty(dict["Program"] as? String) ?? arguments.first.flatMap(nonEmpty) ?? nonEmpty(dict["BundleProgram"] as? String)

        let keepAlive: OptimizeKeepAlive
        switch dict["KeepAlive"] {
        case let value as Bool: keepAlive = value ? .always : .no
        case is [String: Any]: keepAlive = .conditional
        default: keepAlive = .no
        }

        var calendar: [OptimizeCalendarInterval] = []
        if let one = dict["StartCalendarInterval"] as? [String: Any] {
            calendar = [interval(from: one)]
        } else if let many = dict["StartCalendarInterval"] as? [[String: Any]] {
            calendar = many.map(interval(from:))
        }

        var associated: [String] = []
        if let one = dict["AssociatedBundleIdentifiers"] as? String {
            associated = [one]
        } else if let many = dict["AssociatedBundleIdentifiers"] as? [Any] {
            associated = many.compactMap { $0 as? String }
        }

        let watches = !((dict["WatchPaths"] as? [Any]) ?? []).isEmpty
            || !((dict["QueueDirectories"] as? [Any]) ?? []).isEmpty
            || (dict["StartOnMount"] as? Bool ?? false)

        var problem: OptimizeAgentProblem?
        // Só caminhos absolutos dão para conferir; "sh" ou BundleProgram relativo ficam de fora.
        if let program, program.hasPrefix("/"), isMissing(program) {
            problem = .missingProgram(program)
        } else if program == nil {
            problem = .invalidPlist
        }

        return OptimizeLaunchAgent(
            url: url, scope: scope, label: label, program: program, arguments: arguments,
            runAtLoad: dict["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
            startInterval: (dict["StartInterval"] as? NSNumber)?.intValue, calendarIntervals: calendar,
            watchesFiles: watches, disabledInPlist: dict["Disabled"] as? Bool ?? false,
            associatedBundleIDs: associated, problem: problem
        )
    }

    /// Não existe de verdade? Sem permissão para conferir conta como "existe" (sem falso positivo).
    /// Programa num volume externo desconectado também não conta como quebrado.
    public static func pathIsMissing(_ path: String) -> Bool {
        var st = stat()
        if stat(path, &st) == 0 { return false }
        let error = errno
        guard error == ENOENT || error == ENOTDIR else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Volumes" {
            var volume = stat()
            if stat("/Volumes/" + components[1], &volume) != 0 { return false }
        }
        return true
    }

    private static func interval(from dict: [String: Any]) -> OptimizeCalendarInterval {
        func int(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }
        return OptimizeCalendarInterval(minute: int("Minute"), hour: int("Hour"), day: int("Day"),
                                        weekday: int("Weekday"), month: int("Month"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Estado do launchd

/// Foto do launchd num instante (uma chamada de cada comando, em paralelo).
public struct OptimizeRuntimeSnapshot: Sendable {
    public var userServices: [String: OptimizeServiceStatus] = [:]
    public var userDisabled: [String: Bool] = [:]
    public var systemServices: [String: OptimizeServiceStatus] = [:]
    public var systemDisabled: [String: Bool] = [:]

    public init(userServices: [String: OptimizeServiceStatus] = [:], userDisabled: [String: Bool] = [:],
                systemServices: [String: OptimizeServiceStatus] = [:], systemDisabled: [String: Bool] = [:]) {
        self.userServices = userServices
        self.userDisabled = userDisabled
        self.systemServices = systemServices
        self.systemDisabled = systemDisabled
    }

    public static func capture(includeSystem: Bool) async -> OptimizeRuntimeSnapshot {
        let launchctl = OptimizeLaunchctl.executable
        async let list = OptimizeProcess.run(launchctl, ["list"])
        async let disabled = OptimizeProcess.run(launchctl, ["print-disabled", OptimizeLaunchctl.guiDomain()])
        async let system = includeSystem ? OptimizeProcess.run(launchctl, ["print", "system"], timeout: 15) : nil
        async let systemDisabled = includeSystem ? OptimizeProcess.run(launchctl, ["print-disabled", "system"]) : nil

        var snapshot = OptimizeRuntimeSnapshot()
        snapshot.userServices = OptimizeLaunchctlParser.parseList(await list.stdout)
        snapshot.userDisabled = OptimizeLaunchctlParser.parseDisabled(await disabled.stdout)
        if let output = await system?.stdout { snapshot.systemServices = OptimizeLaunchctlParser.parseDomainServices(output) }
        if let output = await systemDisabled?.stdout { snapshot.systemDisabled = OptimizeLaunchctlParser.parseDisabled(output) }
        return snapshot
    }
}

// MARK: - Inventário

public struct OptimizeAgentSource: Sendable, Hashable {
    public let directory: URL
    public let scope: OptimizeAgentScope

    public init(directory: URL, scope: OptimizeAgentScope) {
        self.directory = directory
        self.scope = scope
    }
}

public enum OptimizeAgentScanner {
    public static var defaultSources: [OptimizeAgentSource] {
        OptimizeAgentScope.allCases.map { OptimizeAgentSource(directory: $0.directory, scope: $0) }
    }

    /// Inventário completo: .plist + estado do launchd + app dono. Rode fora da main.
    public static func inventory(sources: [OptimizeAgentSource] = defaultSources,
                                 progress: (@Sendable (String) -> Void)? = nil) async -> [OptimizeLaunchAgent] {
        progress?("Lendo os arquivos .plist…")
        var agents = readAgents(in: sources, isCancelled: { Task.isCancelled })
        guard !Task.isCancelled else { return [] }
        progress?("Consultando o launchd…")
        let snapshot = await OptimizeRuntimeSnapshot.capture(includeSystem: agents.contains { $0.scope == .systemDaemon })
        guard !Task.isCancelled else { return [] }
        agents = apply(snapshot, to: agents)
        progress?("Identificando os apps…")
        resolveOwners(&agents)
        return sorted(agents)
    }

    /// Lê os .plist das pastas (sem descer em subpastas). Respeita as pastas ignoradas.
    public static func readAgents(in sources: [OptimizeAgentSource],
                                  isExcluded: (URL) -> Bool = Exclusions.isExcluded,
                                  isSafeToRemove: (URL) -> Bool = { SafetyGuard.check($0).isAllowed },
                                  isMissing: (String) -> Bool = OptimizeLaunchPlist.pathIsMissing,
                                  isCancelled: () -> Bool = { false }) -> [OptimizeLaunchAgent] {
        let fm = FileManager.default
        var agents: [OptimizeLaunchAgent] = []
        for source in sources {
            guard !isExcluded(source.directory),
                  let files = try? fm.contentsOfDirectory(at: source.directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles])
            else { continue }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if isCancelled() { return agents }
                guard file.pathExtension.lowercased() == "plist", !isExcluded(file) else { continue }
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                // Um .plist de launchd tem poucos KB; acima de 1 MB não é um.
                guard (values?.fileSize ?? 0) < 1_000_000,
                      let data = try? Data(contentsOf: file) else { continue }
                var agent = OptimizeLaunchPlist.parse(data, url: file, scope: source.scope, isMissing: isMissing)
                agent.isRemovable = source.scope == .user && isSafeToRemove(file)
                agents.append(agent)
            }
        }
        return agents
    }

    /// Cruza com o launchd. Agentes de /Library/LaunchAgents também carregam na sessão do usuário.
    public static func apply(_ snapshot: OptimizeRuntimeSnapshot, to agents: [OptimizeLaunchAgent]) -> [OptimizeLaunchAgent] {
        agents.map { agent in
            var agent = agent
            let isDaemon = agent.scope == .systemDaemon
            let status = isDaemon ? snapshot.systemServices[agent.label] : snapshot.userServices[agent.label]
            agent.isLoaded = status != nil
            agent.pid = status?.pid
            agent.lastExitStatus = status?.lastExitStatus
            agent.disabledOverride = isDaemon ? snapshot.systemDisabled[agent.label] : snapshot.userDisabled[agent.label]
            return agent
        }
    }

    /// Palpite do app dono: AssociatedBundleIdentifiers → .app no caminho do programa → prefixo do rótulo.
    public static func resolveOwners(_ agents: inout [OptimizeLaunchAgent],
                                     lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        var cache: [String: URL?] = [:]
        func app(for bundleID: String) -> URL? {
            if let cached = cache[bundleID] { return cached }
            let url = lookup(bundleID)
            cache[bundleID] = url
            return url
        }
        for index in agents.indices {
            let agent = agents[index]
            var found: URL?
            for id in agent.associatedBundleIDs where found == nil { found = app(for: id) }
            if found == nil, let program = agent.program, let bundle = appBundlePath(in: program), exists(bundle) {
                found = URL(fileURLWithPath: bundle)
            }
            if found == nil {
                for prefix in labelPrefixes(agent.label) where found == nil { found = app(for: prefix) }
            }
            if let found {
                agents[index].owner = OptimizeOwnerApp(name: appName(found), url: found)
            }
        }
    }

    /// O .app mais externo no caminho (um helper dentro de Foo.app pertence a Foo.app).
    static func appBundlePath(in programPath: String) -> String? {
        guard programPath.hasPrefix("/") else { return nil }
        var path = ""
        for component in programPath.split(separator: "/", omittingEmptySubsequences: true) {
            path += "/" + component
            if component.lowercased().hasSuffix(".app") { return path }
        }
        return nil
    }

    /// "com.spotify.client.startuphelper" → o rótulo inteiro e prefixos até 2 partes.
    static func labelPrefixes(_ label: String) -> [String] {
        let parts = label.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return [] }
        return stride(from: parts.count, through: 2, by: -1).map { parts.prefix($0).joined(separator: ".") }
    }

    static func appName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Do usuário primeiro; dentro de cada grupo, quebrados no topo e depois por nome.
    public static func sorted(_ agents: [OptimizeLaunchAgent]) -> [OptimizeLaunchAgent] {
        let order = Dictionary(uniqueKeysWithValues: OptimizeAgentScope.allCases.enumerated().map { ($1, $0) })
        return agents.sorted { a, b in
            if a.scope != b.scope { return order[a.scope, default: 0] < order[b.scope, default: 0] }
            if a.isBroken != b.isBroken { return a.isBroken }
            let byName = a.displayName.localizedStandardCompare(b.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.label < b.label
        }
    }
}
