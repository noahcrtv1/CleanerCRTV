import Darwin
import Foundation

// MARK: - Processador

/// Uso do processador. Frações de 0 a 1.
public struct MonitorCPU: Sendable, Equatable {
    public var total: Double
    public var user: Double
    public var system: Double
    /// Um valor por núcleo lógico, na ordem do kernel.
    public var perCore: [Double]
    /// Média de carga de 1, 5 e 15 minutos.
    public var loadAverage: [Double]

    public init(total: Double = 0, user: Double = 0, system: Double = 0,
                perCore: [Double] = [], loadAverage: [Double] = []) {
        self.total = total
        self.user = user
        self.system = system
        self.perCore = perCore
        self.loadAverage = loadAverage
    }

    public static let zero = MonitorCPU()
}

/// Ticks acumulados de um núcleo desde o boot. São de 32 bits e dão a volta.
public struct MonitorCPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Diferença tolerante à volta do contador.
    public func delta(since old: MonitorCPUTicks) -> MonitorCPUTicks {
        MonitorCPUTicks(user: user &- old.user, system: system &- old.system,
                        idle: idle &- old.idle, nice: nice &- old.nice)
    }

    var busy: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) }
    var total: UInt64 { busy + UInt64(idle) }
}

// MARK: - Memória

public enum MonitorMemoryPressure: Int, Sendable, Equatable, CaseIterable {
    case normal = 1, warning = 2, critical = 4

    /// Valor de `kern.memorystatus_vm_pressure_level`.
    public init(level: Int) {
        switch level {
        case ..<2: self = .normal
        case 2..<4: self = .warning
        default: self = .critical
        }
    }
}

public struct MonitorSwap: Sendable, Equatable {
    public var total: Int64
    public var used: Int64
    public var encrypted: Bool

    public init(total: Int64, used: Int64, encrypted: Bool) {
        self.total = max(0, total)
        self.used = min(max(0, used), max(0, total))
        self.encrypted = encrypted
    }

    public init(_ xsw: xsw_usage) {
        self.init(total: Int64(clamping: xsw.xsu_total), used: Int64(clamping: xsw.xsu_used),
                  encrypted: xsw.xsu_encrypted != 0)
    }

    /// Lê o buffer cru de `vm.swapusage`. nil se o tamanho não bate.
    public static func parse(_ data: Data) -> MonitorSwap? {
        guard data.count >= MemoryLayout<xsw_usage>.size else { return nil }
        let xsw = data.withUnsafeBytes { $0.loadUnaligned(as: xsw_usage.self) }
        return MonitorSwap(xsw)
    }

    public static let none = MonitorSwap(total: 0, used: 0, encrypted: false)
}

/// Memória com a mesma semântica do Monitor de Atividade.
public struct MonitorMemory: Sendable, Equatable {
    public var total: Int64
    /// Memória de apps (anônima, sem a parte purgeable).
    public var app: Int64
    public var wired: Int64
    public var compressed: Int64
    /// Arquivos em cache (o macOS devolve quando alguém precisa).
    public var cached: Int64
    public var free: Int64
    public var pressure: MonitorMemoryPressure
    /// 0…1, a partir de `kern.memorystatus_level`. nil se o sistema não informar.
    public var pressureFraction: Double?
    public var swap: MonitorSwap

    public var used: Int64 { app + wired + compressed }
    public var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    public init(total: Int64 = 0, app: Int64 = 0, wired: Int64 = 0, compressed: Int64 = 0,
                cached: Int64 = 0, free: Int64 = 0, pressure: MonitorMemoryPressure = .normal,
                pressureFraction: Double? = nil, swap: MonitorSwap = .none) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.pressure = pressure
        self.pressureFraction = pressureFraction
        self.swap = swap
    }

    /// Quebra a partir de `host_statistics64(HOST_VM_INFO64)`. As partes nunca somam mais que `physical`.
    public init(vm: vm_statistics64, pageSize: UInt64, physical: UInt64,
                pressure: MonitorMemoryPressure = .normal, pressureFraction: Double? = nil,
                swap: MonitorSwap = .none) {
        let page = max(1, pageSize)
        let internalPages = UInt64(vm.internal_page_count)
        let purgeable = UInt64(vm.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let cachedPages = UInt64(vm.external_page_count) + purgeable

        // Multiplicação saturada: um tamanho de página absurdo não pode derrubar o app.
        func bytes(_ pages: UInt64) -> UInt64 {
            let product = pages.multipliedReportingOverflow(by: page)
            return product.overflow ? .max : product.partialValue
        }
        let cap = physical
        let app = min(bytes(appPages), cap)
        let wired = min(bytes(UInt64(vm.wire_count)), cap - app)
        let compressed = min(bytes(UInt64(vm.compressor_page_count)), cap - app - wired)
        let used = app + wired + compressed
        let cached = min(bytes(cachedPages), cap - used)
        let free = cap - used - cached

        self.init(total: Int64(clamping: physical), app: Int64(clamping: app), wired: Int64(clamping: wired),
                  compressed: Int64(clamping: compressed), cached: Int64(clamping: cached),
                  free: Int64(clamping: free), pressure: pressure, pressureFraction: pressureFraction, swap: swap)
    }

    public static let zero = MonitorMemory()
}

// MARK: - Disco, rede, bateria

/// Par de contadores crescentes desde o boot (rede: recebido/enviado; disco: lido/gravado).
public struct MonitorIOCount: Sendable, Equatable {
    public var input: UInt64
    public var output: UInt64

    public init(input: UInt64, output: UInt64) {
        self.input = input
        self.output = output
    }
}

public struct MonitorDiskIO: Sendable, Equatable {
    public var readPerSecond: Double
    public var writePerSecond: Double
    /// Acumulado desde o boot.
    public var totalRead: UInt64
    public var totalWritten: UInt64

    public init(readPerSecond: Double = 0, writePerSecond: Double = 0, totalRead: UInt64 = 0, totalWritten: UInt64 = 0) {
        self.readPerSecond = readPerSecond
        self.writePerSecond = writePerSecond
        self.totalRead = totalRead
        self.totalWritten = totalWritten
    }

    public static let zero = MonitorDiskIO()
}

public struct MonitorNetwork: Sendable, Equatable {
    public var inPerSecond: Double
    public var outPerSecond: Double
    /// Acumulado desde o boot (interfaces físicas).
    public var totalIn: UInt64
    public var totalOut: UInt64

    public init(inPerSecond: Double = 0, outPerSecond: Double = 0, totalIn: UInt64 = 0, totalOut: UInt64 = 0) {
        self.inPerSecond = inPerSecond
        self.outPerSecond = outPerSecond
        self.totalIn = totalIn
        self.totalOut = totalOut
    }

    public static let zero = MonitorNetwork()
}

public struct MonitorBattery: Sendable, Equatable {
    /// 0…1
    public var level: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isCharged: Bool
    /// Só na bateria; nil enquanto o macOS calcula.
    public var minutesToEmpty: Int?
    /// Só carregando; nil enquanto o macOS calcula.
    public var minutesToFull: Int?
    public var cycleCount: Int?
    /// Capacidade máxima atual sobre a de fábrica (0…1).
    public var health: Double?
    /// °C
    public var temperature: Double?

    public init(level: Double, isCharging: Bool, isPluggedIn: Bool, isCharged: Bool,
                minutesToEmpty: Int? = nil, minutesToFull: Int? = nil,
                cycleCount: Int? = nil, health: Double? = nil, temperature: Double? = nil) {
        self.level = level
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isCharged = isCharged
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.cycleCount = cycleCount
        self.health = health
        self.temperature = temperature
    }

    /// Lê a descrição de uma fonte de energia (`IOPSGetPowerSourceDescription`).
    /// nil se não for a bateria interna.
    public static func parse(_ d: [String: Any]) -> MonitorBattery? {
        guard (d["Type"] as? String) == "InternalBattery",
              (d["Is Present"] as? Bool) ?? true,
              let current = (d["Current Capacity"] as? NSNumber)?.doubleValue else { return nil }
        let maxCapacity = (d["Max Capacity"] as? NSNumber)?.doubleValue ?? 100
        let level = maxCapacity > 0 ? min(1, max(0, current / maxCapacity)) : 0
        let charging = (d["Is Charging"] as? Bool) ?? false
        let plugged = (d["Power Source State"] as? String) == "AC Power"
        let charged = (d["Is Charged"] as? Bool) ?? false
        // -1 = "calculando"; 0 aparece quando não se aplica.
        let toEmpty = (d["Time to Empty"] as? NSNumber)?.intValue ?? -1
        let toFull = (d["Time to Full Charge"] as? NSNumber)?.intValue ?? -1
        return MonitorBattery(level: level, isCharging: charging, isPluggedIn: plugged, isCharged: charged,
                              minutesToEmpty: !plugged && toEmpty > 0 ? toEmpty : nil,
                              minutesToFull: charging && toFull > 0 ? toFull : nil)
    }
}

public enum MonitorThermalState: Int, Sendable, Equatable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Processos

public struct MonitorProcess: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var path: String?
    /// Pacote .app mais externo que contém o executável (agrupa os "Helpers").
    public var appBundlePath: String?
    /// 1 = um núcleo inteiro (pode passar de 1, como no Monitor de Atividade).
    public var cpu: Double
    /// Memória física atribuída (phys_footprint), a mesma coluna "Memória" do Monitor de Atividade.
    public var memory: Int64

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, path: String? = nil, appBundlePath: String? = nil, cpu: Double = 0, memory: Int64 = 0) {
        self.pid = pid
        self.name = name
        self.path = path
        self.appBundlePath = appBundlePath
        self.cpu = cpu
        self.memory = memory
    }
}

/// Processos somados por app (o app e todos os seus ajudantes).
public struct MonitorAppGroup: Sendable, Equatable, Identifiable {
    public var bundlePath: String
    public var name: String
    public var cpu: Double
    public var memory: Int64
    public var pids: [Int32]
    /// O executável principal do pacote (caminho mais curto do grupo).
    public var mainPID: Int32

    public var id: String { bundlePath }
}

// MARK: - Amostra

public struct MonitorSystemInfo: Sendable, Equatable {
    public var cpuBrand: String
    public var logicalCores: Int
    /// nil em Macs Intel (não há níveis de desempenho).
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var physicalMemory: Int64
    public var osVersion: String
}

public struct MonitorSnapshot: Sendable {
    public var date: Date
    /// nil enquanto não há duas leituras próximas o bastante para calcular a diferença.
    public var cpu: MonitorCPU?
    public var network: MonitorNetwork?
    public var disk: MonitorDiskIO?
    public var memory: MonitorMemory
    public var volume: VolumeUsage?
    public var battery: MonitorBattery?
    public var thermal: MonitorThermalState
    public var uptime: TimeInterval
    /// Só quando pedido (modo detalhado).
    public var processes: [MonitorProcess]?
    public var apps: [MonitorAppGroup]?
    /// false na primeira leitura de processos: a CPU de cada um ainda é 0.
    public var processCPUValid: Bool

    public var ratesValid: Bool { cpu != nil }
}
