import Darwin
import Foundation

/// Estado de um serviço no launchd (`launchctl list` / `launchctl print`).
public struct OptimizeServiceStatus: Sendable, Hashable {
    /// PID quando está rodando.
    public var pid: Int?
    /// Último código de saída (negativo = sinal).
    public var lastExitStatus: Int?

    public init(pid: Int? = nil, lastExitStatus: Int? = nil) {
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }
}

/// Leitura das saídas de texto do `launchctl`. Tolerante: linha que não reconhece é ignorada.
public enum OptimizeLaunchctlParser {
    /// `launchctl list`: "PID\tStatus\tLabel", com "-" quando não há valor.
    public static func parseList(_ output: String) -> [String: OptimizeServiceStatus] {
        var result: [String: OptimizeServiceStatus] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            var fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if fields.count < 3 {
                fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            }
            guard fields.count == 3 else { continue }
            let pidField = fields[0].trimmingCharacters(in: .whitespaces)
            let statusField = fields[1].trimmingCharacters(in: .whitespaces)
            let label = fields[2].trimmingCharacters(in: .whitespaces)
            if pidField == "PID" || label.isEmpty { continue }
            guard pidField == "-" || Int(pidField) != nil else { continue }
            result[label] = OptimizeServiceStatus(pid: Int(pidField).flatMap { $0 > 0 ? $0 : nil },
                                                  lastExitStatus: Int(statusField))
        }
        return result
    }

    /// `launchctl print-disabled <domínio>`: `"rótulo" => disabled|enabled` (ou `true|false` nas versões antigas).
    /// Devolve rótulo → está desativado.
    public static func parseDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let arrow = line.range(of: "\" =>", options: .backwards) else { continue }
            let label = String(line[line.index(after: line.startIndex)..<arrow.lowerBound])
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty else { continue }
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// Bloco `services = { … }` do `launchctl print <domínio>`: "PID  último-código  rótulo".
    /// PID 0 = carregado mas parado; "-" ou "(pe)" no código = sem valor.
    public static func parseDomainServices(_ output: String) -> [String: OptimizeServiceStatus] {
        var result: [String: OptimizeServiceStatus] = [:]
        var inside = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inside {
                if line == "services = {" { inside = true }
                continue
            }
            if line == "}" { break }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 3, let pid = Int(tokens[0]) else { continue }
            let label = tokens[2...].joined(separator: " ")
            result[label] = OptimizeServiceStatus(pid: pid > 0 ? pid : nil, lastExitStatus: Int(tokens[1]))
        }
        return result
    }

    /// Linha `path = …` do `launchctl print <serviço>`: o .plist de onde o serviço foi carregado.
    public static func parseServicePath(_ output: String) -> String? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("path = ") else { continue }
            let path = line.dropFirst("path = ".count).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        return nil
    }
}

/// Comandos do `launchctl` para os agentes do próprio usuário. Os de /Library nunca passam por aqui.
public enum OptimizeLaunchctl {
    public static let executable = "/bin/launchctl"
    public static var currentUID: uid_t { getuid() }

    public static func guiDomain(uid: uid_t = currentUID) -> String { "gui/\(uid)" }

    public static func serviceTarget(_ label: String, uid: uid_t = currentUID) -> String { "gui/\(uid)/\(label)" }

    /// Rótulo utilizável como alvo de serviço (sem barra, quebra de linha ou caractere de controle).
    public static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 512 && !label.hasPrefix("-")
            && !label.contains("/") && !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Desativar: descarrega agora e marca como desativado (não volta no próximo login).
    public static func disableCommands(label: String, uid: uid_t = currentUID) -> [[String]] {
        [["bootout", serviceTarget(label, uid: uid)], ["disable", serviceTarget(label, uid: uid)]]
    }

    /// Ativar: tira a marca de desativado e carrega a partir do .plist.
    public static func enableCommands(label: String, plist: URL, uid: uid_t = currentUID) -> [[String]] {
        [["enable", serviceTarget(label, uid: uid)], ["bootstrap", guiDomain(uid: uid), plist.path]]
    }

    // MARK: - Execução

    /// Desativa um agente do usuário.
    public static func disable(_ agent: OptimizeLaunchAgent) async -> OptimizeActionResult {
        guard let label = manageableLabel(agent) else { return .refused }
        let commands = disableCommands(label: label)
        let bootout = await OptimizeProcess.run(executable, commands[0], timeout: 20)
        guard bootout.succeeded || isNotLoadedStatus(bootout) else { return .failed(bootout.errorLine) }
        let disable = await OptimizeProcess.run(executable, commands[1])
        return disable.succeeded ? .ok : .failed(disable.errorLine)
    }

    /// Ativa e carrega um agente do usuário.
    public static func enable(_ agent: OptimizeLaunchAgent) async -> OptimizeActionResult {
        guard let label = manageableLabel(agent) else { return .refused }
        let commands = enableCommands(label: label, plist: agent.url)
        let enable = await OptimizeProcess.run(executable, commands[0])
        guard enable.succeeded else { return .failed(enable.errorLine) }
        let bootstrap = await OptimizeProcess.run(executable, commands[1])
        if bootstrap.succeeded { return .ok }
        // 5 e 37 costumam significar "já estava carregado": confere antes de acusar erro.
        if await isLoaded(label: label) { return .ok }
        return .failed(bootstrap.errorLine)
    }

    /// Descarrega um agente do usuário (antes ou depois de remover o .plist).
    @discardableResult
    public static func bootout(label: String) async -> OptimizeActionResult {
        guard isValidLabel(label) else { return .refused }
        let result = await OptimizeProcess.run(executable, ["bootout", serviceTarget(label)], timeout: 20)
        return result.succeeded || isNotLoadedStatus(result) ? .ok : .failed(result.errorLine)
    }

    /// bootout que "falhou" porque não havia nada carregado: 3 = No such process,
    /// 113 = serviço não encontrado, 36 = já está saindo.
    static func isNotLoadedStatus(_ result: OptimizeProcessResult) -> Bool {
        result.launchError == nil && !result.timedOut && !result.cancelled && [3, 36, 113].contains(result.status)
    }

    /// Descarrega só se o launchd carregou o serviço a partir deste .plist: um agente de /Library
    /// pode ter o mesmo rótulo e não deve cair junto.
    @discardableResult
    public static func bootoutIfLoaded(from plist: URL, label: String) async -> OptimizeActionResult {
        guard isValidLabel(label) else { return .refused }
        let info = await OptimizeProcess.run(executable, ["print", serviceTarget(label)])
        guard info.succeeded else { return .ok }
        if let loadedFrom = OptimizeLaunchctlParser.parseServicePath(info.stdout),
           URL(fileURLWithPath: loadedFrom).standardizedFileURL.path != plist.standardizedFileURL.path {
            return .ok
        }
        return await bootout(label: label)
    }

    public static func isLoaded(label: String) async -> Bool {
        guard isValidLabel(label) else { return false }
        return await OptimizeProcess.run(executable, ["print", serviceTarget(label)]).succeeded
    }

    private static func manageableLabel(_ agent: OptimizeLaunchAgent) -> String? {
        guard agent.scope == .user, agent.problem != .invalidPlist, isValidLabel(agent.label) else { return nil }
        return agent.label
    }
}

public enum OptimizeActionResult: Sendable, Equatable {
    case ok
    case failed(String)
    /// Recusado antes de rodar (agente do sistema ou rótulo inválido).
    case refused

    public var isOK: Bool { self == .ok }

    public var message: String? {
        switch self {
        case .ok: nil
        case .failed(let reason): reason
        case .refused: "Este agente não pode ser alterado pelo CleanerCRTV"
        }
    }
}
