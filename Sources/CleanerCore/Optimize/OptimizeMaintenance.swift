import Darwin
import Foundation

public enum OptimizePrivilege: String, Sendable, Hashable {
    /// Roda como o usuário, sem senha.
    case user
    /// Sempre pede a senha de administrador (janela padrão do macOS).
    case admin
    /// Tenta sem senha; se o macOS recusar, oferece repetir com senha.
    case userThenAdmin
}

/// Um passo executado como usuário: executável absoluto + argumentos (nunca shell).
public struct OptimizeTaskStep: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]

    public init(_ executable: String, _ arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct OptimizeMaintenanceTask: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let explanation: String
    public let symbol: String
    public let privilege: OptimizePrivilege
    /// Passos sem senha (privilege `.user` / `.userThenAdmin`).
    public let steps: [OptimizeTaskStep]
    /// Linha FIXA para `do shell script … with administrator privileges`. Nunca recebe dado de fora.
    public let adminCommand: String?
    /// Aviso mostrado no cartão (ex.: Spotlight lento).
    public let warning: String?
    /// Pergunta antes de rodar.
    public let needsConfirmation: Bool
    public let confirmationMessage: String?
    public let duration: String
    public let successMessage: String
    public let timeout: TimeInterval

    public var needsPassword: Bool { privilege == .admin }
}

public enum OptimizeMaintenanceCatalog {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public static let freeMemory = OptimizeMaintenanceTask(
        id: "freeMemory", title: "Liberar memória inativa",
        explanation: "Esvazia a memória que guarda arquivos usados há pouco. Ajuda quando o Mac fica lento depois de muito tempo ligado.",
        symbol: "memorychip", privilege: .admin, steps: [], adminCommand: "/usr/sbin/purge",
        warning: nil, needsConfirmation: false, confirmationMessage: nil,
        duration: "Alguns segundos", successMessage: "Memória inativa liberada.", timeout: 180
    )

    public static let flushDNS = OptimizeMaintenanceTask(
        id: "flushDNS", title: "Limpar cache de DNS",
        explanation: "Resolve sites que não abrem ou que abrem o endereço antigo depois de uma mudança na rede.",
        symbol: "network", privilege: .admin, steps: [],
        adminCommand: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder",
        warning: nil, needsConfirmation: false, confirmationMessage: nil,
        duration: "Instantâneo", successMessage: "Cache de DNS limpo.", timeout: 60
    )

    public static let reindexSpotlight = OptimizeMaintenanceTask(
        id: "reindexSpotlight", title: "Reindexar o Spotlight",
        explanation: "Apaga e refaz o índice de busca do disco de inicialização. Use quando o Spotlight não acha arquivos que existem.",
        symbol: "magnifyingglass", privilege: .admin, steps: [], adminCommand: "/usr/bin/mdutil -E /",
        warning: "O Spotlight fica lento e incompleto por um tempo enquanto reindexa.",
        needsConfirmation: true,
        confirmationMessage: "Enquanto o índice é refeito (de minutos a algumas horas), a busca fica incompleta e o Mac pode esquentar um pouco.",
        duration: "Começa na hora; termina em segundo plano", successMessage: "O Spotlight começou a reindexar o disco.", timeout: 120
    )

    public static let rebuildLaunchServices = OptimizeMaintenanceTask(
        id: "rebuildLaunchServices", title: "Reconstruir o banco do “Abrir com”",
        explanation: "Corrige apps duplicados ou faltando no menu “Abrir com” e ícones de documentos errados.",
        symbol: "square.stack.3d.up", privilege: .user,
        // -kill e -domain saíram do lsregister: -gc limpa registros velhos e -apps refaz os apps dos domínios.
        steps: [OptimizeTaskStep(lsregister, ["-gc"]),
                OptimizeTaskStep(lsregister, ["-r", "-f", "-apps", "local,system,user"])],
        adminCommand: nil, warning: nil, needsConfirmation: false, confirmationMessage: nil,
        duration: "Pode levar alguns minutos",
        successMessage: "Banco do “Abrir com” refeito. Os menus se atualizam em alguns segundos.", timeout: 900
    )

    public static let resetQuickLook = OptimizeMaintenanceTask(
        id: "resetQuickLook", title: "Limpar cache do Quick Look",
        explanation: "Refaz miniaturas e pré-visualizações. Útil quando o Quick Look mostra imagens antigas ou não abre.",
        symbol: "eye", privilege: .user,
        steps: [OptimizeTaskStep("/usr/bin/qlmanage", ["-r", "cache"]), OptimizeTaskStep("/usr/bin/qlmanage", ["-r"])],
        adminCommand: nil, warning: nil, needsConfirmation: false, confirmationMessage: nil,
        duration: "Alguns segundos", successMessage: "Cache do Quick Look limpo.", timeout: 60
    )

    public static let restartFinderDock = OptimizeMaintenanceTask(
        id: "restartFinderDock", title: "Reiniciar o Finder e o Dock",
        explanation: "Destrava o Finder, atualiza ícones que ficaram para trás e deixa o Dock leve de novo.",
        symbol: "dock.rectangle", privilege: .user,
        steps: [OptimizeTaskStep("/usr/bin/killall", ["Finder", "Dock"])],
        adminCommand: nil, warning: nil, needsConfirmation: true,
        confirmationMessage: "As janelas do Finder fecham e reabrem sozinhas. Nada é perdido.",
        duration: "Instantâneo", successMessage: "Finder e Dock reiniciados.", timeout: 30
    )

    public static let verifyDisk = OptimizeMaintenanceTask(
        id: "verifyDisk", title: "Verificar o disco",
        explanation: "Primeiros Socorros só de leitura: confere a estrutura do disco de inicialização sem alterar nada.",
        symbol: "stethoscope", privilege: .userThenAdmin,
        steps: [OptimizeTaskStep("/usr/sbin/diskutil", ["verifyVolume", "/"])],
        // Com senha, saída não zero apagaria o relatório; o veredito sai do próprio texto.
        adminCommand: "/usr/sbin/diskutil verifyVolume / 2>&1 || true",
        warning: nil, needsConfirmation: false, confirmationMessage: nil,
        duration: "Alguns minutos; o Mac pode ficar mais lento", successMessage: "Disco verificado.", timeout: 1800
    )

    public static let all: [OptimizeMaintenanceTask] = [
        freeMemory, flushDNS, restartFinderDock, resetQuickLook, rebuildLaunchServices, reindexSpotlight, verifyDisk,
    ]

    public static func task(id: String) -> OptimizeMaintenanceTask? { all.first { $0.id == id } }
}

// MARK: - Execução

public struct OptimizeTaskOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case success, warning, failure, cancelled }

    public var status: Status
    public var message: String
    /// Saída do comando, resumida (para "Detalhes").
    public var details: String?
    /// Falhou sem senha: vale oferecer "Tentar com senha".
    public var canRetryAsAdmin = false
    public var date = Date()

    public init(status: Status, message: String, details: String? = nil, canRetryAsAdmin: Bool = false, date: Date = Date()) {
        self.status = status
        self.message = message
        self.details = details
        self.canRetryAsAdmin = canRetryAsAdmin
        self.date = date
    }

    public var didRun: Bool { status == .success || status == .warning }
}

public enum OptimizeMaintenanceRunner {
    /// Roda a tarefa fora da main. `asAdmin` só vale para tarefas `.userThenAdmin`.
    public static func run(_ task: OptimizeMaintenanceTask, asAdmin: Bool = false) async -> OptimizeTaskOutcome {
        let useAdmin = task.privilege == .admin || (asAdmin && task.privilege == .userThenAdmin)
        let freeBefore = task.id == OptimizeMaintenanceCatalog.freeMemory.id ? OptimizeMemory.freeBytes() : nil

        if useAdmin {
            guard let command = task.adminCommand else {
                return OptimizeTaskOutcome(status: .failure, message: "Esta tarefa não roda com senha.")
            }
            switch await OptimizeAppleScript.runAdminShell(command) {
            case .success(let output):
                return finish(task, output: output, exitCode: 0, freeBefore: freeBefore, ranAsAdmin: true)
            case .failure(let error) where error.isUserCancelled:
                return OptimizeTaskOutcome(status: .cancelled, message: "Você cancelou o pedido de senha.")
            case .failure(let error):
                // Saída não zero do comando: o AppleScript devolve o código e o stderr.
                if task.id == OptimizeMaintenanceCatalog.verifyDisk.id {
                    return finish(task, output: error.message, exitCode: Int32(clamping: error.code), freeBefore: nil, ranAsAdmin: true)
                }
                return OptimizeTaskOutcome(status: .failure, message: "Não deu certo: \(error.message)")
            }
        }

        var output = ""
        for step in task.steps {
            guard !Task.isCancelled else { return OptimizeTaskOutcome(status: .cancelled, message: "Interrompido.") }
            let result = await OptimizeProcess.run(step.executable, step.arguments, timeout: task.timeout)
            output += result.stdout + result.stderr
            if result.cancelled { return OptimizeTaskOutcome(status: .cancelled, message: "Interrompido.") }
            if task.id == OptimizeMaintenanceCatalog.verifyDisk.id {
                return finish(task, output: output, exitCode: result.timedOut ? -1 : result.status, freeBefore: nil, ranAsAdmin: false)
            }
            guard result.succeeded else {
                return OptimizeTaskOutcome(status: .failure, message: "Não deu certo: \(result.errorLine)",
                                           details: OptimizeDiskVerify.tail(output),
                                           canRetryAsAdmin: task.privilege == .userThenAdmin)
            }
        }
        return finish(task, output: output, exitCode: 0, freeBefore: freeBefore, ranAsAdmin: false)
    }

    static func finish(_ task: OptimizeMaintenanceTask, output: String, exitCode: Int32,
                       freeBefore: Int64?, ranAsAdmin: Bool) -> OptimizeTaskOutcome {
        let details = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : OptimizeDiskVerify.tail(output)
        switch task.id {
        case OptimizeMaintenanceCatalog.verifyDisk.id:
            let verdict = OptimizeDiskVerify.verdict(output: output, exitCode: exitCode)
            let message = OptimizeDiskVerify.message(for: verdict, volume: OptimizeDiskVerify.volumeName(in: output))
            switch verdict {
            case .ok(let warnings):
                return OptimizeTaskOutcome(status: warnings > 0 ? .warning : .success, message: message, details: details)
            case .problems:
                return OptimizeTaskOutcome(status: .warning, message: message, details: details)
            case .couldNotVerify:
                return OptimizeTaskOutcome(status: .failure, message: message, details: details,
                                           canRetryAsAdmin: !ranAsAdmin && task.privilege == .userThenAdmin)
            }
        case OptimizeMaintenanceCatalog.freeMemory.id:
            if let freeBefore, let freeAfter = OptimizeMemory.freeBytes(), freeAfter > freeBefore {
                return OptimizeTaskOutcome(status: .success,
                                           message: "Memória livre: \(freeBefore.formattedBytes) → \(freeAfter.formattedBytes).")
            }
            return OptimizeTaskOutcome(status: .success, message: task.successMessage)
        default:
            return OptimizeTaskOutcome(status: .success, message: task.successMessage, details: details)
        }
    }
}

/// Última execução de cada tarefa (UserDefaults).
public struct OptimizeMaintenanceLog: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func lastRun(_ taskID: String) -> Date? {
        defaults.object(forKey: "optimize.lastRun.\(taskID)") as? Date
    }

    public func lastMessage(_ taskID: String) -> String? {
        defaults.string(forKey: "optimize.lastMessage.\(taskID)")
    }

    public func record(_ taskID: String, outcome: OptimizeTaskOutcome) {
        guard outcome.didRun else { return }
        defaults.set(outcome.date, forKey: "optimize.lastRun.\(taskID)")
        defaults.set(outcome.message, forKey: "optimize.lastMessage.\(taskID)")
    }
}

// MARK: - Memória

public enum OptimizeMemory {
    /// Memória livre agora (páginas livres + especulativas).
    public static func freeBytes() -> Int64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pageSize = Int64(sysconf(_SC_PAGESIZE))
        return (Int64(stats.free_count) + Int64(stats.speculative_count)) * pageSize
    }
}

// MARK: - Verificação do disco

public enum OptimizeDiskVerify {
    public enum Verdict: Sendable, Equatable {
        case ok(warnings: Int)
        case problems
        case couldNotVerify(String)
    }

    /// Lê a saída do `diskutil verifyVolume`.
    public static func verdict(output: String, exitCode: Int32) -> Verdict {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let lower = output.lowercased()
        let warnings = lines.filter { $0.lowercased().hasPrefix("warning:") }.count

        if let fsck = lines.last(where: { $0.hasPrefix("File system check exit code is") }),
           let code = Int(fsck.split(separator: " ").last ?? "") {
            return code == 0 ? .ok(warnings: warnings) : .problems
        }
        let problemMarkers = ["needs to be repaired", "is corrupt", "appears to be corrupt", "could not be repaired", "invalid sibling link"]
        if problemMarkers.contains(where: lower.contains) { return .problems }
        if exitCode == 0, lower.contains("appears to be ok") { return .ok(warnings: warnings) }

        let reason = lines.first { $0.lowercased().hasPrefix("error") }
            ?? lines.last { !$0.isEmpty }
            ?? "código de saída \(exitCode)"
        return .couldNotVerify(reason)
    }

    /// "Started file system verification on disk3s1s1 (Macintosh HD)" → "Macintosh HD".
    public static func volumeName(in output: String) -> String? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Started file system verification on"),
                  let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close
            else { continue }
            let name = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    public static func message(for verdict: Verdict, volume: String?) -> String {
        let prefix = volume.map { "\($0): " } ?? ""
        switch verdict {
        case .ok(0):
            return "\(prefix)nenhum problema encontrado."
        case .ok(let warnings):
            return "\(prefix)sem erros, com \(warnings) \(warnings == 1 ? "aviso" : "avisos"). Veja os detalhes."
        case .problems:
            return "\(prefix)o macOS encontrou problemas. Abra o Utilitário de Disco ▸ Primeiros Socorros para reparar."
        case .couldNotVerify(let reason):
            return "Não foi possível verificar: \(reason)"
        }
    }

    /// Últimas linhas da saída (a parte que interessa fica no fim).
    public static func tail(_ output: String, lines count: Int = 40) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
        return lines.suffix(count).joined(separator: "\n")
    }
}
