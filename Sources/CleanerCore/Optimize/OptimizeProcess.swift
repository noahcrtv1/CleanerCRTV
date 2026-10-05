import Darwin
import Foundation

/// Resultado de um comando externo.
public struct OptimizeProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut = false
    public var cancelled = false
    /// Preenchido quando o executável nem chegou a rodar.
    public var launchError: String?

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false,
                cancelled: Bool = false, launchError: String? = nil) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.launchError = launchError
    }

    public var succeeded: Bool { launchError == nil && !timedOut && !cancelled && status == 0 }

    /// Primeira linha útil do erro (para mostrar ao usuário).
    public var errorLine: String {
        if let launchError { return launchError }
        if timedOut { return "Demorou demais e foi interrompido" }
        if cancelled { return "Cancelado" }
        let text = stderr.isEmpty ? stdout : stderr
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? "Código de saída \(status)"
    }
}

/// Roda executáveis com lista de argumentos (nunca via shell), fora da main, com tempo-limite
/// e cancelamento (cancelar a Task encerra o processo).
public enum OptimizeProcess {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) async -> OptimizeProcessResult {
        let handle = OptimizeProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout, handle: handle))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                            handle: OptimizeProcessHandle) -> OptimizeProcessResult {
        guard executable.hasPrefix("/") else {
            return OptimizeProcessResult(status: -1, launchError: "Caminho de executável inválido")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return OptimizeProcessResult(status: -1, launchError: "Não foi possível executar \(URL(fileURLWithPath: executable).lastPathComponent)")
        }
        handle.attach(process)

        let timer = DispatchWorkItem { handle.expire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // As duas saídas são lidas ao mesmo tempo: um pipe cheio travaria o processo.
        let errBox = OptimizeDataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        timer.cancel()

        return OptimizeProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self),
            timedOut: handle.didExpire,
            cancelled: handle.isCancelled
        )
    }
}

/// Guarda o processo para o cancelamento e o tempo-limite (podem chegar de outras threads).
final class OptimizeProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var expired = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    var didExpire: Bool { lock.withLock { expired } }

    func attach(_ process: Process) {
        let shouldStop = lock.withLock { () -> Bool in
            self.process = process
            return cancelled
        }
        if shouldStop { stop(process) }
    }

    func cancel() {
        let current = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        if let current { stop(current) }
    }

    func expire() {
        let current = lock.withLock { () -> Process? in
            guard let process, process.isRunning else { return nil }
            expired = true
            return process
        }
        if let current { stop(current) }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        // Quem ignora SIGTERM leva SIGKILL 2 s depois.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

final class OptimizeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    var data: Data {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
