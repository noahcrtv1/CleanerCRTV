import Foundation

/// Contas puras do monitor (sem chamadas ao sistema), testáveis isoladamente.
public enum MonitorMath {
    /// Acima disto a diferença é tratada como contador reiniciado, não como tráfego real.
    static let maxPlausibleRate: Double = 100e9

    /// Uso de CPU entre duas leituras de `host_processor_info`. nil sem leitura anterior.
    public static func cpuUsage(previous: [MonitorCPUTicks], current: [MonitorCPUTicks]) -> MonitorCPU? {
        let count = min(previous.count, current.count)
        guard count > 0 else { return nil }
        var perCore: [Double] = []
        perCore.reserveCapacity(count)
        var user: UInt64 = 0, system: UInt64 = 0, total: UInt64 = 0
        for i in 0..<count {
            let d = current[i].delta(since: previous[i])
            perCore.append(d.total > 0 ? Double(d.busy) / Double(d.total) : 0)
            user += UInt64(d.user) + UInt64(d.nice)
            system += UInt64(d.system)
            total += d.total
        }
        guard total > 0 else { return MonitorCPU(perCore: perCore) }
        let u = Double(user) / Double(total)
        let s = Double(system) / Double(total)
        return MonitorCPU(total: min(1, u + s), user: u, system: s, perCore: perCore)
    }

    /// Bytes por segundo entre duas leituras de um contador crescente.
    /// Contador que voltou (interface reiniciada) ou salto impossível dão 0.
    public static func rate(previous: UInt64, current: UInt64, seconds: Double) -> Double {
        guard seconds > 0, seconds.isFinite, current >= previous else { return 0 }
        let value = Double(current - previous) / seconds
        return value <= maxPlausibleRate ? value : 0
    }

    /// Soma as taxas de vários contadores (uma interface ou um disco cada). Só entra quem aparece
    /// nas duas leituras: um disco recém-conectado não vira pico com o total acumulado dele.
    public static func rates<Key: Hashable>(previous: [Key: MonitorIOCount], current: [Key: MonitorIOCount],
                                            seconds: Double) -> (input: Double, output: Double) {
        var input = 0.0, output = 0.0
        for (key, now) in current {
            guard let old = previous[key] else { continue }
            input += rate(previous: old.input, current: now.input, seconds: seconds)
            output += rate(previous: old.output, current: now.output, seconds: seconds)
        }
        return (input, output)
    }

    public static func totals<Key: Hashable>(_ counters: [Key: MonitorIOCount]) -> MonitorIOCount {
        counters.values.reduce(into: MonitorIOCount(input: 0, output: 0)) {
            $0.input &+= $1.input
            $0.output &+= $1.output
        }
    }

    /// Converte unidades de `mach_absolute_time` (e de `rusage_info`) em nanossegundos sem estourar.
    public static func machToNanoseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom != 0, numer != denom else { return ticks }
        let d = UInt64(denom)
        // Produto em 128 bits; se nem assim couber, satura em vez de derrubar o app.
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        guard product.high < d else { return .max }
        return d.dividingFullWidth(product).quotient
    }

    /// Fração de um núcleo usada por um processo (1 = 100%).
    public static func cpuFraction(cpuNanos: UInt64, wallNanos: UInt64) -> Double {
        wallNanos > 0 ? Double(cpuNanos) / Double(wallNanos) : 0
    }

    /// Só interfaces físicas (Ethernet/Wi-Fi e celular). Túneis de VPN, pontes e AWDL
    /// repetem o tráfego que já passa por elas.
    public static func isCountedInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    /// Saúde da bateria: capacidade máxima atual / capacidade de fábrica.
    /// Em Apple Silicon `MaxCapacity` vem em %, então só vale como mAh quando passa de 100.
    public static func batteryHealth(nominal: Int? = nil, rawMax: Int?, max: Int?, design: Int?) -> Double? {
        guard let design, design > 0 else { return nil }
        let legacy = max.flatMap { $0 > 100 ? $0 : nil }
        guard let capacity = [nominal, rawMax, legacy].compactMap({ $0 }).first(where: { $0 > 0 }) else { return nil }
        return Swift.min(1, Double(capacity) / Double(design))
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Bar.app/Contents/MacOS/Bar" → "/Applications/Foo.app"
    public static func outermostAppBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        return bundle.count > 5 && bundle.hasPrefix("/") ? bundle : nil
    }

    /// Soma processos por pacote .app. Processos fora de apps ficam de fora.
    public static func groupByApp(_ processes: [MonitorProcess]) -> [MonitorAppGroup] {
        var groups: [String: MonitorAppGroup] = [:]
        var mainPathLength: [String: Int] = [:]
        for process in processes {
            guard let bundle = process.appBundlePath else { continue }
            let length = process.path?.utf8.count ?? Int.max
            if var group = groups[bundle] {
                group.cpu += process.cpu
                group.memory += process.memory
                group.pids.append(process.pid)
                if length < mainPathLength[bundle, default: .max] {
                    group.mainPID = process.pid
                    mainPathLength[bundle] = length
                }
                groups[bundle] = group
            } else {
                let name = (bundle as NSString).lastPathComponent
                groups[bundle] = MonitorAppGroup(bundlePath: bundle, name: String(name.dropLast(4)),
                                                 cpu: process.cpu, memory: process.memory,
                                                 pids: [process.pid], mainPID: process.pid)
                mainPathLength[bundle] = length
            }
        }
        return Array(groups.values)
    }
}

// MARK: - Histórico

/// Fila circular de tamanho fixo (histórico dos gráficos). Sem realocar depois de cheia.
public struct MonitorRingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    /// Posição do mais antigo quando cheia.
    private var head = 0

    public init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var isFull: Bool { storage.count == capacity }

    /// Do mais antigo ao mais recente.
    public var elements: [Element] {
        head == 0 ? storage : Array(storage[head...] + storage[..<head])
    }

    public var last: Element? {
        storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count]
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

extension MonitorRingBuffer: Sendable where Element: Sendable {}

// MARK: - Texto

public enum MonitorFormat {
    public static var decimalSeparator: String { Locale.current.decimalSeparator ?? "," }

    /// "0 KB/s", "8,4 KB/s", "40 KB/s", "1,2 MB/s", "120 MB/s" (base 1000, como o Finder).
    public static func rate(_ bytesPerSecond: Double, separator: String = decimalSeparator) -> String {
        let units = ["KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond.isFinite ? Swift.max(0, bytesPerSecond) / 1000 : 0
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return "\(number(value, separator: separator)) \(units[unit])"
    }

    /// "12%". `decimals: 1` → "12,3%" (coluna de processos).
    public static func percent(_ fraction: Double, decimals: Int = 0, separator: String = decimalSeparator) -> String {
        // Teto bem acima de qualquer valor real (CPU de processo passa de 100%), só para o Int não estourar.
        let value = fraction.isFinite ? Swift.min(Swift.max(0, fraction), 1e9) * 100 : 0
        guard decimals > 0 else { return "\(Int(value.rounded()))%" }
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10)\(separator)\(tenths % 10)%"
    }

    /// Memória em base 1024, como o Monitor de Atividade: "24 GB", "18,8 GB", "512 MB".
    public static func memory(_ bytes: Int64, separator: String = decimalSeparator) -> String {
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(Swift.max(0, bytes)) / 1024
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        guard value < 99.95 else { return "\(Int(value.rounded())) \(units[unit])" }
        let tenths = Int((value * 10).rounded())
        let text = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10)\(separator)\(tenths % 10)"
        return "\(text) \(units[unit])"
    }

    /// "3 d 4 h", "5 h 12 min", "7 min".
    public static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(Swift.min(Swift.max(0, seconds.isFinite ? seconds : 0), 1e12)) / 60
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(rest) min" }
        return "\(rest) min"
    }

    /// "3 h 20 min", "45 min".
    public static func minutes(_ total: Int) -> String {
        let total = Swift.max(0, total)
        let hours = total / 60, rest = total % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Uma casa decimal abaixo de 10; inteiro a partir daí.
    private static func number(_ value: Double, separator: String) -> String {
        if !(value >= 0.05) { return "0" }
        if value < 9.95 {
            let tenths = Int((value * 10).rounded())
            return "\(tenths / 10)\(separator)\(tenths % 10)"
        }
        return "\(Int(Swift.min(value, 1e15).rounded()))"
    }
}

// MARK: - Encerrar apps

/// Quem pode ser encerrado pelo monitor: só apps comuns do usuário (com janela e Dock),
/// nunca componentes do sistema nem o próprio CleanerCRTV.
public enum MonitorTerminationPolicy {
    static let protectedPrefixes = ["/System/Library/", "/System/iOSSupport/", "/Library/Apple/",
                                    "/usr/", "/bin/", "/sbin/"]
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.Spotlight", "com.apple.SecurityAgent", "com.apple.coreservices.uiagent",
    ]

    /// `isRegularApp` = `NSRunningApplication.activationPolicy == .regular`.
    public static func canTerminate(pid: Int32, bundlePath: String?, bundleIdentifier: String?,
                                    isRegularApp: Bool, ownPID: Int32) -> Bool {
        guard isRegularApp, pid > 1, pid != ownPID, let bundlePath, bundlePath.hasSuffix(".app") else { return false }
        if let bundleIdentifier, protectedBundleIDs.contains(bundleIdentifier) { return false }
        let path = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        return !protectedPrefixes.contains { path.hasPrefix($0) }
    }

    /// Apps de sistema ficam fora da lista "mais memória" do menu (não dá para fazer nada com eles).
    public static func isSystemBundle(_ bundlePath: String) -> Bool {
        protectedPrefixes.contains { bundlePath.hasPrefix($0) }
    }
}
