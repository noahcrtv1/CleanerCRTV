import Darwin
import Foundation

/// Lê o estado da máquina sob demanda. Guarda as leituras anteriores para calcular taxas
/// (CPU, rede, disco, CPU por processo). Roda fora da main thread por ser um actor.
public actor MonitorSampler {
    /// Dados fixos da máquina (lidos uma vez).
    public static let systemInfo = MonitorSystem.systemInfo()

    /// Intervalo máximo entre leituras para a diferença ainda fazer sentido
    /// (depois de dormir ou de o monitor ficar parado, recomeça do zero).
    static let maxGap: Double = 20
    /// Leituras mais próximas que isto dão taxas ruidosas: espera a próxima.
    static let minGap: Double = 0.5

    private let host = mach_host_self()
    private let clock = ContinuousClock()
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private let bootTime = MonitorSystem.bootTime()

    // Base para as taxas
    private var lastInstant: ContinuousClock.Instant?
    private var lastTicks: [MonitorCPUTicks] = []
    private var lastNet: [String: MonitorIOCount] = [:]
    private var lastDisk: [UInt64: MonitorIOCount] = [:]
    private var netBuffer: [UInt8] = []

    // Leituras caras, com validade própria
    private var volume: VolumeUsage?
    private var volumeAt: ContinuousClock.Instant?
    private var battery: MonitorBattery?
    private var batteryAt: ContinuousClock.Instant?
    private var batteryDetails: (cycles: Int?, health: Double?, temperature: Double?) = (nil, nil, nil)
    private var batteryDetailsAt: ContinuousClock.Instant?

    // Processos
    private struct Identity {
        var start: UInt64
        var name: String
        var path: String?
        var bundle: String?
    }
    private var identities: [pid_t: Identity] = [:]
    private var lastProcessTimes: [pid_t: (start: UInt64, cpu: UInt64)] = [:]
    private var lastProcessInstant: ContinuousClock.Instant?
    private var lastProcesses: [MonitorProcess] = []
    private var lastProcessesValid = false
    private var pidBuffer: [pid_t] = []

    public init() {}

    /// Uma leitura. `detailed` inclui processos e atualiza disco/bateria com mais frequência
    /// (só quando alguma tela detalhada está à vista).
    public func sample(detailed: Bool) -> MonitorSnapshot {
        let now = clock.now
        let elapsed = lastInstant.map { Self.seconds(now - $0) }
        let tooSoon = elapsed.map { $0 < Self.minGap } ?? false
        let ratesValid = elapsed.map { $0 >= Self.minGap && $0 <= Self.maxGap } ?? false

        // Taxas
        var cpu: MonitorCPU?
        var network: MonitorNetwork?
        var disk: MonitorDiskIO?
        if !tooSoon {
            let ticks = MonitorSystem.cpuTicks(host: host)
            let net = MonitorSystem.networkCounters(buffer: &netBuffer)
            let io = MonitorSystem.diskCounters()
            if ratesValid, let seconds = elapsed {
                cpu = MonitorMath.cpuUsage(previous: lastTicks, current: ticks)
                cpu?.loadAverage = MonitorSystem.loadAverage()
                if let net {
                    let rates = MonitorMath.rates(previous: lastNet, current: net, seconds: seconds)
                    let totals = MonitorMath.totals(net)
                    network = MonitorNetwork(inPerSecond: rates.input, outPerSecond: rates.output,
                                             totalIn: totals.input, totalOut: totals.output)
                }
                if let io {
                    let rates = MonitorMath.rates(previous: lastDisk, current: io, seconds: seconds)
                    let totals = MonitorMath.totals(io)
                    disk = MonitorDiskIO(readPerSecond: rates.input, writePerSecond: rates.output,
                                         totalRead: totals.input, totalWritten: totals.output)
                }
            }
            lastTicks = ticks
            lastNet = net ?? [:]
            lastDisk = io ?? [:]
            lastInstant = now
        }

        // Memória
        let physical = UInt64(ProcessInfo.processInfo.physicalMemory)
        let memory: MonitorMemory
        if let vm = MonitorSystem.vmStatistics(host: host) {
            memory = MonitorMemory(vm: vm, pageSize: MonitorSystem.pageSize, physical: physical,
                                   pressure: MonitorSystem.pressureLevel(), pressureFraction: MonitorSystem.pressureFraction(),
                                   swap: MonitorSystem.swapUsage())
        } else {
            memory = MonitorMemory(total: Int64(clamping: physical))
        }

        // "Disponível" do volume consulta o espaço purgeable (dezenas de ms): bem espaçado.
        if Self.isStale(volumeAt, now: now, maxAge: detailed ? 15 : 120) {
            volume = VolumeUsage.startup()
            volumeAt = now
        }
        if Self.isStale(batteryAt, now: now, maxAge: detailed ? 10 : 60) {
            battery = MonitorSystem.battery()
            batteryAt = now
        }
        if battery != nil, Self.isStale(batteryDetailsAt, now: now, maxAge: 300) {
            batteryDetails = MonitorSystem.batteryDetails()
            batteryDetailsAt = now
        }
        var fullBattery = battery
        fullBattery?.cycleCount = batteryDetails.cycles
        fullBattery?.health = batteryDetails.health
        fullBattery?.temperature = batteryDetails.temperature

        // Processos
        var processes: [MonitorProcess]?
        var apps: [MonitorAppGroup]?
        var processCPUValid = false
        if detailed {
            let result = sampleProcesses(now: now)
            processes = result.processes
            apps = MonitorMath.groupByApp(result.processes)
            processCPUValid = result.valid
        } else if lastProcessInstant != nil {
            // Sem tela detalhada: solta a base e os caches (a próxima abertura recomeça do zero).
            lastProcessTimes = [:]
            lastProcessInstant = nil
            lastProcesses = []
            identities = [:]
        }

        return MonitorSnapshot(date: Date(), cpu: cpu, network: network, disk: disk, memory: memory,
                               volume: volume, battery: fullBattery,
                               thermal: MonitorThermalState(ProcessInfo.processInfo.thermalState),
                               uptime: bootTime.map { max(0, Date().timeIntervalSince($0)) } ?? ProcessInfo.processInfo.systemUptime,
                               processes: processes, apps: apps, processCPUValid: processCPUValid)
    }

    // MARK: - Processos

    /// Só dá para ler processos do próprio usuário; os outros são pulados em silêncio.
    private func sampleProcesses(now: ContinuousClock.Instant) -> (processes: [MonitorProcess], valid: Bool) {
        let elapsed = lastProcessInstant.map { Self.seconds(now - $0) }
        // Chamado de novo logo em seguida (tela reaberta): repete a leitura anterior em vez de zerar a CPU.
        if let elapsed, elapsed < Self.minGap { return (lastProcesses, lastProcessesValid) }
        let valid = elapsed.map { $0 >= Self.minGap && $0 <= Self.maxGap } ?? false
        let wallNanos = UInt64(max(0, elapsed ?? 0) * 1_000_000_000)

        let estimate = Int(proc_listallpids(nil, 0))
        guard estimate > 0 else { return ([], false) }
        if pidBuffer.count < estimate + 64 { pidBuffer = [pid_t](repeating: 0, count: estimate + 128) }
        let found = pidBuffer.withUnsafeMutableBytes { Int(proc_listallpids($0.baseAddress, Int32($0.count))) }
        let count = min(max(0, found), pidBuffer.count)

        var processes: [MonitorProcess] = []
        processes.reserveCapacity(count)
        var times: [pid_t: (start: UInt64, cpu: UInt64)] = [:]
        times.reserveCapacity(count)
        for i in 0..<count {
            let pid = pidBuffer[i]
            guard pid > 0 else { continue }
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            let start = usage.ri_proc_start_abstime
            let cpuTime = usage.ri_user_time &+ usage.ri_system_time
            times[pid] = (start, cpuTime)

            var fraction = 0.0
            if valid, let previous = lastProcessTimes[pid], previous.start == start, cpuTime >= previous.cpu {
                let nanos = MonitorMath.machToNanoseconds(cpuTime - previous.cpu, numer: timebase.numer, denom: timebase.denom)
                fraction = MonitorMath.cpuFraction(cpuNanos: nanos, wallNanos: wallNanos)
            }
            let identity = identity(for: pid, start: start)
            processes.append(MonitorProcess(pid: pid, name: identity.name, path: identity.path,
                                            appBundlePath: identity.bundle, cpu: fraction,
                                            memory: Int64(clamping: usage.ri_phys_footprint)))
        }
        lastProcessTimes = times
        lastProcessInstant = now
        lastProcesses = processes
        lastProcessesValid = valid
        if identities.count > times.count + 256 {
            identities = identities.filter { times[$0.key] != nil }
        }
        return (processes, valid)
    }

    /// Nome e caminho mudam só quando o pid é reaproveitado (início diferente): guarda em cache.
    private func identity(for pid: pid_t, start: UInt64) -> Identity {
        if let cached = identities[pid], cached.start == start { return cached }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = length > 0 ? MonitorSystem.string(from: pathBuffer) : nil
        var name = path.map { ($0 as NSString).lastPathComponent } ?? ""
        if name.isEmpty {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
                name = MonitorSystem.string(from: nameBuffer)
            }
        }
        let identity = Identity(start: start, name: name.isEmpty ? "Processo \(pid)" : name, path: path,
                                bundle: path.flatMap(MonitorMath.outermostAppBundle))
        identities[pid] = identity
        return identity
    }

    // MARK: - Tempo

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func isStale(_ instant: ContinuousClock.Instant?, now: ContinuousClock.Instant, maxAge: Double) -> Bool {
        guard let instant else { return true }
        return seconds(now - instant) >= maxAge
    }
}
