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

    /// Bytes recebidos/enviados desde o boot por interface física (contadores de 64 bits).
    /// `buffer` é reaproveitado entre chamadas para não alocar a cada leitura.
    static func networkCounters(buffer: inout [UInt8]) -> [String: MonitorIOCount]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var needed = 0
        guard Darwin.sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        if buffer.count < needed { buffer = [UInt8](repeating: 0, count: needed + 4096) }
        var size = buffer.count
        let status = buffer.withUnsafeMutableBytes { Darwin.sysctl(&mib, 6, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { parseInterfaceList(UnsafeRawBufferPointer(rebasing: $0[..<min(size, $0.count)])) }
    }

    /// Percorre as mensagens RTM_IFINFO2 de NET_RT_IFLIST2. O nome vem do `sockaddr_dl` logo
    /// depois do cabeçalho (sem `if_indextoname`, que faria outra chamada por interface).
    static func parseInterfaceList(_ raw: UnsafeRawBufferPointer) -> [String: MonitorIOCount] {
        let headerSize = MemoryLayout<if_msghdr2>.size
        var result: [String: MonitorIOCount] = [:]
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= raw.count {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let length = Int(header.ifm_msglen)
            guard length > 0, offset + length <= raw.count else { break }
            if Int32(header.ifm_type) == RTM_IFINFO2, length >= headerSize {
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if message.ifm_flags & IFF_LOOPBACK == 0,
                   let name = linkName(raw, from: offset + headerSize, to: offset + length),
                   MonitorMath.isCountedInterface(name) {
                    result[name] = MonitorIOCount(input: message.ifm_data.ifi_ibytes, output: message.ifm_data.ifi_obytes)
                }
            }
            offset += length
        }
        return result
    }

    private static let nameLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_nlen) ?? 5
    private static let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8

    private static func linkName(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int) -> String? {
        guard start + nameOffset <= end, Int32(raw[start + 1]) == AF_LINK else { return nil }
        let length = Int(raw[start + nameLengthOffset])
        guard length > 0, start + nameOffset + length <= end else { return nil }
        // Nomes curtos ("en0", "pdp_ip0") cabem na string inline: sem alocar.
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[(start + nameOffset)..<(start + nameOffset + length)]),
                      as: UTF8.self)
    }

    // MARK: Disco

    /// Bytes lidos/gravados desde o boot por driver de armazenamento em bloco (chave: id no IORegistry).
    static func diskCounters() -> [UInt64: MonitorIOCount]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: [UInt64: MonitorIOCount] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
               let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                result[id] = MonitorIOCount(input: (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                                            output: (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
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
