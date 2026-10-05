import Foundation

public struct OptimizeScriptError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// -128: o usuário fechou o pedido de senha ou de permissão.
    public var isUserCancelled: Bool { code == -128 }
    /// -1743 / -1744: o macOS negou a Automação (Ajustes ▸ Privacidade ▸ Automação).
    public var isNotPermitted: Bool { code == -1743 || code == -1744 }
    /// -1712: o app alvo não respondeu a tempo (ou o pedido de permissão ficou sem resposta).
    public var isTimeout: Bool { code == -1712 }

    init(info: NSDictionary) {
        code = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
        message = (info[NSAppleScript.errorMessage] as? String)
            ?? (info[NSAppleScript.errorBriefMessage] as? String)
            ?? "Erro \(code) do AppleScript"
    }
}

/// Executa AppleScript no próprio processo (os pedidos de senha e de permissão aparecem em nome do
/// CleanerCRTV), fora da main. Cada fila é serial; a de administrador é separada para que uma
/// verificação de disco demorada não segure a leitura dos itens de início.
enum OptimizeAppleScript {
    static let eventsQueue = DispatchQueue(label: "CleanerCRTV.optimize.applescript", qos: .userInitiated)
    static let adminQueue = DispatchQueue(label: "CleanerCRTV.optimize.applescript.admin", qos: .userInitiated)

    static func run<T: Sendable>(_ source: String, on queue: DispatchQueue = eventsQueue,
                                 transform: @escaping @Sendable (NSAppleEventDescriptor) -> T) async -> Result<T, OptimizeScriptError> {
        await withCheckedContinuation { continuation in
            queue.async {
                var info: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .failure(OptimizeScriptError(code: -1, message: "Script inválido")))
                    return
                }
                let result = script.executeAndReturnError(&info)
                if let info {
                    continuation.resume(returning: .failure(OptimizeScriptError(info: info)))
                } else {
                    continuation.resume(returning: .success(transform(result)))
                }
            }
        }
    }

    /// Chama um handler do script passando os argumentos como dados (nada é colado no código-fonte).
    static func call<T: Sendable>(_ source: String, handler: String, arguments: [String],
                                  transform: @escaping @Sendable (NSAppleEventDescriptor) -> T) async -> Result<T, OptimizeScriptError> {
        await withCheckedContinuation { continuation in
            eventsQueue.async {
                var info: NSDictionary?
                guard let script = NSAppleScript(source: source), script.compileAndReturnError(&info) else {
                    let error = info.map(OptimizeScriptError.init(info:)) ?? OptimizeScriptError(code: -1, message: "Script inválido")
                    continuation.resume(returning: .failure(error))
                    return
                }
                let event = subroutineEvent(handler: handler, arguments: arguments)
                let result = script.executeAppleEvent(event, error: &info)
                if let info {
                    continuation.resume(returning: .failure(OptimizeScriptError(info: info)))
                } else {
                    continuation.resume(returning: .success(transform(result)))
                }
            }
        }
    }

    /// `do shell script` com a janela de senha padrão do macOS. Uso interno: só com os comandos
    /// fixos do catálogo de manutenção.
    static func runAdminShell(_ command: String) async -> Result<String, OptimizeScriptError> {
        let source = "do shell script \(literal(command)) with administrator privileges without altering line endings"
        return await run(source, on: adminQueue) { $0.stringValue ?? "" }
    }

    /// Texto como literal de AppleScript (aspas e barras escapadas).
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Evento de sub-rotina ('ascr'/'psbr')

    static func subroutineEvent(handler: String, arguments: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: fourCharCode("ascr"), eventID: fourCharCode("psbr"),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: -1,          // kAutoGenerateReturnID
            transactionID: 0       // kAnyTransactionID
        )
        // Nome do handler sempre em minúsculas: é assim que o AppleScript o registra.
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: fourCharCode("snam"))
        let list = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(list, forKeyword: fourCharCode("----"))
        return event
    }

    static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
