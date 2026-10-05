import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Leituras cruas do sistema (Mach, sysctl, IOKit). Nada aqui guarda estado.
enum MonitorSystem {
    // MARK: CPU

    static func cpuTicks(host: host_t) -> [MonitorCPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        // O kernel aloca o vetor no nosso espaço; sem isto vaza memória a cada leitura.
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        let available = Int(infoCount) / stride
        var result: [MonitorCPUTicks] = []
        result.reserveCapacity(min(Int(cpuCount), available))
        for i in 0..<min(Int(cpuCount), available) {
            let base = i * stride
            result.append(MonitorCPUTicks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                                          system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                                          idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                                          nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return result
    }

    static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }

    // MARK: Memória

    static func vmStatistics(host: host_t) -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    static var pageSize: UInt64 { UInt64(vm_kernel_page_size) }

    static func swapUsage() -> MonitorSwap {
        var xsw = xsw_usage()
        return sysctl("vm.swapusage", into: &xsw) ? MonitorSwap(xsw) : .none
    }

    static func pressureLevel() -> MonitorMemoryPressure {
        var level: Int32 = 0
        return sysctl("kern.memorystatus_vm_pressure_level", into: &level) ? MonitorMemoryPressure(level: Int(level)) : .normal
    }

    /// 0…1. `kern.memorystatus_level` é a % de memória disponível (o mesmo que `memory_pressure` mostra).
    static func pressureFraction() -> Double? {
        var level: Int32 = 0
        guard sysctl("kern.memorystatus_level", into: &level), (0...100).contains(level) else { return nil }
        return 1 - Double(level) / 100
    }

    // MARK: Rede

    /// Bytes recebidos/enviados desde o boot nas interfaces físicas (contadores de 64 bits).
    /// `buffer` e `counted` são reaproveitados entre chamadas para não alocar a cada leitura.
    static func networkCounters(buffer: inout [UInt8], counted: inout [UInt16: Bool]) -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var needed = 0
        guard Darwin.sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        if buffer.count < needed { buffer = [UInt8](repeating: 0, count: needed + 4096) }
        var size = buffer.count
        let status = buffer.withUnsafeMutableBytes { Darwin.sysctl(&mib, 6, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }

        var rx: UInt64 = 0, tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let index = message.ifm_index
                    let include: Bool
                    if let cached = counted[index] {
                        include = cached
                    } else {
                        include = (message.ifm_flags & IFF_LOOPBACK) == 0
                            && interfaceName(index).map(MonitorMath.isCountedInterface) == true
                        counted[index] = include
                    }
                    if include {
                        rx &+= message.ifm_data.ifi_ibytes
                        tx &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += length
            }
        }
        return (rx, tx)
    }

    private static func interfaceName(_ index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        return string(from: name)
    }

    // MARK: Disco

    /// Bytes lidos/gravados desde o boot, somando todos os drivers de armazenamento em bloco.
    static func diskCounters() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }

    // MARK: Bateria

    static func battery() -> MonitorBattery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
               let battery = MonitorBattery.parse(description) {
                return battery
            }
        }
        return nil
    }

    /// Ciclos, saúde e temperatura do registro "AppleSmartBattery". Conforme a versão do macOS,
    /// as capacidades ficam no topo ou dentro de "BatteryData".
    static func batteryDetails() -> (cycles: Int?, health: Double?, temperature: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let data = property("BatteryData") as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            ((property(key) ?? data[key]) as? NSNumber)?.intValue
        }
        let health = MonitorMath.batteryHealth(nominal: int("NominalChargeCapacity"), rawMax: int("AppleRawMaxCapacity"),
                                               max: int("MaxCapacity"), design: int("DesignCapacity"))
        // Centésimos de °C; fora da faixa plausível é lixo do sensor.
        let temperature = int("Temperature").map { Double($0) / 100 }.flatMap { (0...90).contains($0) ? $0 : nil }
        return (int("CycleCount"), health, temperature)
    }

    // MARK: Diversos

    static func bootTime() -> Date? {
        var boot = timeval()
        guard sysctl("kern.boottime", into: &boot), boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }

    static func systemInfo() -> MonitorSystemInfo {
        var performance: Int32 = 0, efficiency: Int32 = 0
        let hasLevels = sysctl("hw.perflevel0.logicalcpu", into: &performance)
            && sysctl("hw.perflevel1.logicalcpu", into: &efficiency)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        return MonitorSystemInfo(cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "Processador",
                                 logicalCores: ProcessInfo.processInfo.activeProcessorCount,
                                 performanceCores: hasLevels ? Int(performance) : nil,
                                 efficiencyCores: hasLevels ? Int(efficiency) : nil,
                                 physicalMemory: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
                                 osVersion: os)
    }

    // MARK: sysctl

    /// Lê um valor de tamanho fixo. Falha se o kernel devolver outro tamanho.
    static func sysctl<T: BitwiseCopyable>(_ name: String, into value: inout T) -> Bool {
        var size = MemoryLayout<T>.size
        let status = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
        return status == 0 && size == MemoryLayout<T>.size
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = string(from: buffer).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func string(from buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress, pointer.contains(0) else { return "" }
            return String(cString: base)
        }
    }
}
