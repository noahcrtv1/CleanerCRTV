import Darwin
import Foundation
import Testing
@testable import CleanerCore

@Suite("Monitor · CPU")
struct MonitorCPUTests {
    @Test func tickDeltaToPercent() throws {
        let before = [MonitorCPUTicks(user: 100, system: 50, idle: 800, nice: 50),
                      MonitorCPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        // Núcleo 0: +30 user, +10 system, +60 idle → 40% ocupado. Núcleo 1: +100 idle → 0%.
        let after = [MonitorCPUTicks(user: 130, system: 60, idle: 860, nice: 50),
                     MonitorCPUTicks(user: 0, system: 0, idle: 1100, nice: 0)]
        let cpu = try #require(MonitorMath.cpuUsage(previous: before, current: after))
        #expect(cpu.perCore.count == 2)
        #expect(abs(cpu.perCore[0] - 0.4) < 1e-9)
        #expect(cpu.perCore[1] == 0)
        // Total: 40 ocupados de 200 ticks.
        #expect(abs(cpu.total - 0.2) < 1e-9)
        #expect(abs(cpu.user - 0.15) < 1e-9)
        #expect(abs(cpu.system - 0.05) < 1e-9)
    }

    @Test func niceCountsAsUser() throws {
        let before = [MonitorCPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let after = [MonitorCPUTicks(user: 0, system: 0, idle: 50, nice: 50)]
        let cpu = try #require(MonitorMath.cpuUsage(previous: before, current: after))
        #expect(cpu.total == 0.5)
        #expect(cpu.user == 0.5)
    }

    @Test func counterWrapAround() throws {
        let before = [MonitorCPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29, nice: 0)]
        // user deu a volta: +20; idle: +40.
        let after = [MonitorCPUTicks(user: 10, system: 0, idle: 10, nice: 0)]
        let cpu = try #require(MonitorMath.cpuUsage(previous: before, current: after))
        #expect(abs(cpu.total - 20.0 / 60.0) < 1e-9)
    }

    @Test func noPreviousOrNoTimeElapsed() throws {
        let ticks = [MonitorCPUTicks(user: 5, system: 5, idle: 5, nice: 0)]
        #expect(MonitorMath.cpuUsage(previous: [], current: ticks) == nil)
        let same = try #require(MonitorMath.cpuUsage(previous: ticks, current: ticks))
        #expect(same.total == 0)
        #expect(same.perCore == [0])
    }

    @Test func processTimeConversion() {
        // Apple Silicon: 125/3 → 24 ticks = 1000 ns.
        #expect(MonitorMath.machToNanoseconds(24, numer: 125, denom: 3) == 1000)
        #expect(MonitorMath.machToNanoseconds(24_000_000, numer: 125, denom: 3) == 1_000_000_000)
        #expect(MonitorMath.machToNanoseconds(12345, numer: 1, denom: 1) == 12345)
        #expect(MonitorMath.machToNanoseconds(10, numer: 5, denom: 0) == 10)
        // Valores enormes: exato enquanto couber em 64 bits, saturado depois (nunca derruba o app).
        #expect(MonitorMath.machToNanoseconds(3_000_000_000_000_000, numer: 125, denom: 3) == 125_000_000_000_000_000)
        #expect(MonitorMath.machToNanoseconds(UInt64.max / 2, numer: 125, denom: 3) == UInt64.max)
        // 1,5 s de CPU em 1 s de relógio = 150% (um núcleo e meio).
        #expect(MonitorMath.cpuFraction(cpuNanos: 1_500_000_000, wallNanos: 1_000_000_000) == 1.5)
        #expect(MonitorMath.cpuFraction(cpuNanos: 10, wallNanos: 0) == 0)
    }
}

@Suite("Monitor · Memória")
struct MonitorMemoryTests {
    let page: UInt64 = 16_384
    let physical: UInt64 = 16 * 1_073_741_824

    func vm(internal internalPages: UInt32, purgeable: UInt32, wired: UInt32, compressor: UInt32, external: UInt32) -> vm_statistics64 {
        var vm = vm_statistics64()
        vm.internal_page_count = internalPages
        vm.purgeable_count = purgeable
        vm.wire_count = wired
        vm.compressor_page_count = compressor
        vm.external_page_count = external
        vm.free_count = 1234
        return vm
    }

    @Test func activityMonitorBreakdown() {
        let stats = vm(internal: 400_000, purgeable: 20_000, wired: 150_000, compressor: 50_000, external: 100_000)
        let memory = MonitorMemory(vm: stats, pageSize: page, physical: physical)
        #expect(memory.app == Int64(380_000 * page))
        #expect(memory.wired == Int64(150_000 * page))
        #expect(memory.compressed == Int64(50_000 * page))
        #expect(memory.cached == Int64(120_000 * page))
        #expect(memory.used == Int64(580_000 * page))
        #expect(memory.app + memory.wired + memory.compressed + memory.cached + memory.free == Int64(physical))
        #expect(abs(memory.usedFraction - Double(580_000 * page) / Double(physical)) < 1e-12)
    }

    @Test func purgeableLargerThanInternalNeverGoesNegative() {
        let memory = MonitorMemory(vm: vm(internal: 10, purgeable: 50, wired: 0, compressor: 0, external: 0),
                                   pageSize: page, physical: physical)
        #expect(memory.app == 0)
        #expect(memory.cached == Int64(50 * page))
    }

    @Test func partsAreClampedToPhysicalMemory() {
        // Contadores inconsistentes (leitura no meio de uma mudança) não podem passar do total.
        let memory = MonitorMemory(vm: vm(internal: 900_000, purgeable: 0, wired: 900_000, compressor: 900_000, external: 900_000),
                                   pageSize: page, physical: physical)
        #expect(memory.used <= memory.total)
        #expect(memory.free == 0)
        #expect(memory.cached == 0)
        #expect(memory.usedFraction == 1)
    }

    @Test func absurdPageSizeSaturatesInsteadOfCrashing() {
        let memory = MonitorMemory(vm: vm(internal: 10, purgeable: 0, wired: 10, compressor: 10, external: 10),
                                   pageSize: .max / 2, physical: physical)
        #expect(memory.total == Int64(physical))
        #expect(memory.app == Int64(physical))
        #expect(memory.used == memory.total)
        #expect(memory.free == 0)
    }

    @Test(arguments: [(0, MonitorMemoryPressure.normal), (1, .normal), (2, .warning), (4, .critical), (7, .critical)])
    func pressureLevels(level: Int, expected: MonitorMemoryPressure) {
        #expect(MonitorMemoryPressure(level: level) == expected)
    }

    @Test func swapFromStruct() {
        let xsw = xsw_usage(xsu_total: 2_147_483_648, xsu_avail: 1_610_612_736, xsu_used: 536_870_912,
                            xsu_pagesize: 16_384, xsu_encrypted: 1)
        let swap = MonitorSwap(xsw)
        #expect(swap.total == 2_147_483_648)
        #expect(swap.used == 536_870_912)
        #expect(swap.encrypted)
    }

    @Test func swapParsesRawSysctlBuffer() throws {
        var xsw = xsw_usage(xsu_total: 1_073_741_824, xsu_avail: 0, xsu_used: 1_073_741_824, xsu_pagesize: 4096, xsu_encrypted: 0)
        let data = withUnsafeBytes(of: &xsw) { Data($0) }
        let swap = try #require(MonitorSwap.parse(data))
        #expect(swap == MonitorSwap(total: 1_073_741_824, used: 1_073_741_824, encrypted: false))
        #expect(MonitorSwap.parse(data.prefix(8)) == nil)
        #expect(MonitorSwap.parse(Data()) == nil)
    }

    @Test func swapUsedNeverExceedsTotal() {
        let swap = MonitorSwap(total: 100, used: 500, encrypted: false)
        #expect(swap.used == 100)
        #expect(MonitorSwap(total: -5, used: -1, encrypted: false) == .none)
    }
}

@Suite("Monitor · Taxas e texto")
struct MonitorRateTests {
    @Test func rateFromCounters() {
        #expect(MonitorMath.rate(previous: 1_000, current: 3_000, seconds: 2) == 1_000)
        #expect(MonitorMath.rate(previous: 0, current: 0, seconds: 2) == 0)
    }

    @Test func counterResetOrWrapGivesZero() {
        // Interface reiniciada: o contador volta para trás. Nada de taxa negativa nem gigante.
        #expect(MonitorMath.rate(previous: 5_000_000, current: 1_000, seconds: 2) == 0)
        #expect(MonitorMath.rate(previous: 10, current: UInt64.max, seconds: 1) == 0)
    }

    @Test func invalidIntervalGivesZero() {
        #expect(MonitorMath.rate(previous: 0, current: 100, seconds: 0) == 0)
        #expect(MonitorMath.rate(previous: 0, current: 100, seconds: -1) == 0)
        #expect(MonitorMath.rate(previous: 0, current: 100, seconds: .nan) == 0)
        #expect(MonitorMath.rate(previous: 0, current: 100, seconds: .infinity) == 0)
    }

    @Test(arguments: [
        (0.0, "0 KB/s"), (20.0, "0 KB/s"), (500.0, "0,5 KB/s"), (8_400.0, "8,4 KB/s"), (40_000.0, "40 KB/s"),
        (999_400.0, "999 KB/s"), (999_600.0, "1,0 MB/s"), (1_234_567.0, "1,2 MB/s"), (120_000_000.0, "120 MB/s"),
        (1_500_000_000.0, "1,5 GB/s"), (-10.0, "0 KB/s"), (Double.nan, "0 KB/s"),
    ])
    func rateText(bytes: Double, expected: String) {
        #expect(MonitorFormat.rate(bytes, separator: ",") == expected)
    }

    @Test func percentText() {
        #expect(MonitorFormat.percent(0.123) == "12%")
        #expect(MonitorFormat.percent(0.995) == "100%")
        #expect(MonitorFormat.percent(-0.2) == "0%")
        #expect(MonitorFormat.percent(0.1234, decimals: 1, separator: ",") == "12,3%")
        #expect(MonitorFormat.percent(2.5, decimals: 1, separator: ",") == "250,0%")
        // Valores fora de qualquer realidade não podem estourar a conversão para Int.
        #expect(!MonitorFormat.percent(1e300, decimals: 1, separator: ",").isEmpty)
        #expect(!MonitorFormat.percent(.greatestFiniteMagnitude).isEmpty)
        #expect(!MonitorFormat.rate(.greatestFiniteMagnitude, separator: ",").isEmpty)
        #expect(!MonitorFormat.uptime(.greatestFiniteMagnitude).isEmpty)
    }

    @Test func memoryText() {
        #expect(MonitorFormat.memory(24 * 1_073_741_824, separator: ",") == "24 GB")
        #expect(MonitorFormat.memory(20_190_000_000, separator: ",") == "18,8 GB")
        #expect(MonitorFormat.memory(512 * 1_048_576, separator: ",") == "512 MB")
        #expect(MonitorFormat.memory(1_395_864_371, separator: ",") == "1,3 GB")
        #expect(MonitorFormat.memory(-1, separator: ",") == "0 KB")
    }

    @Test func durations() {
        #expect(MonitorFormat.uptime(59) == "0 min")
        #expect(MonitorFormat.uptime(7 * 60) == "7 min")
        #expect(MonitorFormat.uptime(5 * 3600 + 12 * 60) == "5 h 12 min")
        #expect(MonitorFormat.uptime(3 * 86_400 + 4 * 3600 + 59) == "3 d 4 h")
        #expect(MonitorFormat.minutes(45) == "45 min")
        #expect(MonitorFormat.minutes(200) == "3 h 20 min")
        #expect(MonitorFormat.minutes(120) == "2 h")
    }

    @Test(arguments: [("en0", true), ("en7", true), ("pdp_ip0", true), ("lo0", false), ("utun3", false),
                      ("awdl0", false), ("llw0", false), ("bridge0", false), ("ipsec0", false), ("anpi0", false)])
    func countedInterfaces(name: String, counted: Bool) {
        #expect(MonitorMath.isCountedInterface(name) == counted)
    }
}

@Suite("Monitor · Histórico")
struct MonitorRingBufferTests {
    @Test func keepsInsertionOrderUntilFull() {
        var ring = MonitorRingBuffer<Int>(capacity: 3)
        #expect(ring.isEmpty)
        #expect(ring.last == nil)
        ring.append(1)
        ring.append(2)
        #expect(ring.elements == [1, 2])
        #expect(ring.last == 2)
        #expect(!ring.isFull)
    }

    @Test func dropsOldestWhenFull() {
        var ring = MonitorRingBuffer<Int>(capacity: 3)
        for value in 1...7 { ring.append(value) }
        #expect(ring.count == 3)
        #expect(ring.isFull)
        #expect(ring.elements == [5, 6, 7])
        #expect(ring.last == 7)
    }

    @Test func ninetySamplesWindow() {
        var ring = MonitorRingBuffer<Double>(capacity: 90)
        for value in 0..<200 { ring.append(Double(value)) }
        #expect(ring.elements.count == 90)
        #expect(ring.elements.first == 110)
        #expect(ring.elements.last == 199)
    }

    @Test func removeAllAndMinimumCapacity() {
        var ring = MonitorRingBuffer<Int>(capacity: 0)
        #expect(ring.capacity == 1)
        ring.append(1)
        ring.append(2)
        #expect(ring.elements == [2])
        ring.removeAll()
        #expect(ring.isEmpty)
        ring.append(3)
        #expect(ring.elements == [3])
    }
}

@Suite("Monitor · Processos e bateria")
struct MonitorProcessTests {
    @Test func outermostBundle() {
        #expect(MonitorMath.outermostAppBundle("/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/A/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(MonitorMath.outermostAppBundle(helper) == "/Applications/Google Chrome.app")
        #expect(MonitorMath.outermostAppBundle("/usr/libexec/trustd") == nil)
        #expect(MonitorMath.outermostAppBundle("/Users/x/Foo.application/bin") == nil)
    }

    @Test func groupsHelpersUnderTheirApp() throws {
        let chrome = "/Applications/Google Chrome.app"
        let processes = [
            MonitorProcess(pid: 10, name: "Google Chrome Helper", path: chrome + "/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                           appBundlePath: chrome, cpu: 0.25, memory: 300),
            MonitorProcess(pid: 5, name: "Google Chrome", path: chrome + "/Contents/MacOS/Google Chrome",
                           appBundlePath: chrome, cpu: 0.5, memory: 700),
            MonitorProcess(pid: 20, name: "trustd", path: "/usr/libexec/trustd", cpu: 0.1, memory: 50),
        ]
        let groups = MonitorMath.groupByApp(processes)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.name == "Google Chrome")
        #expect(group.memory == 1000)
        #expect(abs(group.cpu - 0.75) < 1e-9)
        #expect(Set(group.pids) == [5, 10])
        #expect(group.mainPID == 5)
    }

    @Test func batteryHealth() {
        // Apple Silicon: MaxCapacity em % (100) não serve como mAh.
        #expect(MonitorMath.batteryHealth(rawMax: nil, max: 100, design: 6249) == nil)
        #expect(abs((MonitorMath.batteryHealth(nominal: 5742, rawMax: 5590, max: 100, design: 6249) ?? 0) - 5742.0 / 6249.0) < 1e-9)
        #expect(abs((MonitorMath.batteryHealth(rawMax: 5590, max: 100, design: 6249) ?? 0) - 5590.0 / 6249.0) < 1e-9)
        // Intel: MaxCapacity em mAh.
        #expect(MonitorMath.batteryHealth(rawMax: nil, max: 4500, design: 5000) == 0.9)
        #expect(MonitorMath.batteryHealth(rawMax: 5200, max: nil, design: 5000) == 1)
        #expect(MonitorMath.batteryHealth(rawMax: 5000, max: nil, design: 0) == nil)
    }

    @Test func batteryDescription() throws {
        let onBattery: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 63, "Max Capacity": 100,
                                        "Is Charging": false, "Power Source State": "Battery Power",
                                        "Time to Empty": 462, "Time to Full Charge": 0]
        let battery = try #require(MonitorBattery.parse(onBattery))
        #expect(battery.level == 0.63)
        #expect(!battery.isCharging && !battery.isPluggedIn)
        #expect(battery.minutesToEmpty == 462)
        #expect(battery.minutesToFull == nil)

        let charging: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 80, "Max Capacity": 100,
                                       "Is Charging": true, "Power Source State": "AC Power",
                                       "Time to Empty": 0, "Time to Full Charge": -1]
        let plugged = try #require(MonitorBattery.parse(charging))
        #expect(plugged.isCharging && plugged.isPluggedIn)
        #expect(plugged.minutesToEmpty == nil)
        #expect(plugged.minutesToFull == nil, "-1 = o macOS ainda está calculando")

        #expect(MonitorBattery.parse(["Type": "UPS", "Current Capacity": 50]) == nil)
    }
}

@Suite("Monitor · Leitura real")
struct MonitorSamplerTests {
    /// Só confere faixas válidas; nada aqui depende da carga da máquina.
    @Test func sampleProducesSaneValues() async throws {
        let sampler = MonitorSampler()
        let first = await sampler.sample(detailed: true)
        #expect(!first.ratesValid, "a primeira leitura só serve de base")
        #expect(first.memory.total == Int64(ProcessInfo.processInfo.physicalMemory))
        #expect(first.memory.used <= first.memory.total)
        #expect(first.uptime > 0)
        let processes = try #require(first.processes)
        #expect(processes.contains { $0.pid == getpid() }, "o próprio processo de teste é legível")

        try await Task.sleep(for: .milliseconds(700))
        let second = await sampler.sample(detailed: true)
        let cpu = try #require(second.cpu)
        #expect((0...1).contains(cpu.total))
        #expect(cpu.perCore.count == ProcessInfo.processInfo.processorCount)
        #expect(cpu.perCore.allSatisfy { (0...1).contains($0) })
        #expect(second.processCPUValid)
        #expect((second.network?.inPerSecond ?? 0) >= 0)
        #expect((second.disk?.readPerSecond ?? 0) >= 0)

        // Sem modo detalhado não há processos.
        let third = await sampler.sample(detailed: false)
        #expect(third.processes == nil)
        #expect(third.apps == nil)
    }

    @Test func systemInfoIsFilled() {
        let info = MonitorSampler.systemInfo
        #expect(info.logicalCores > 0)
        #expect(info.physicalMemory > 0)
        #expect(info.osVersion.hasPrefix("macOS "))
    }
}

@Suite("Monitor · Contadores por interface e disco")
struct MonitorCounterTests {
    @Test func summedRatesIgnoreNewAndResetCounters() {
        let before: [String: MonitorIOCount] = [
            "en0": MonitorIOCount(input: 1_000, output: 500),
            "en1": MonitorIOCount(input: 9_000_000, output: 9_000_000),
        ]
        let after: [String: MonitorIOCount] = [
            "en0": MonitorIOCount(input: 3_000, output: 1_500),
            // Interface reiniciada: contador voltou. Não pode virar taxa negativa nem gigante.
            "en1": MonitorIOCount(input: 10, output: 20),
            // Recém-conectada com 5 GB acumulados: só conta a partir da próxima leitura.
            "en7": MonitorIOCount(input: 5_000_000_000, output: 5_000_000_000),
        ]
        let rates = MonitorMath.rates(previous: before, current: after, seconds: 2)
        #expect(rates.input == 1_000)
        #expect(rates.output == 500)
        #expect(MonitorMath.rates(previous: [:], current: after, seconds: 2) == (0, 0))
        #expect(MonitorMath.rates(previous: before, current: after, seconds: 0) == (0, 0))
    }

    @Test func totalsWrapInsteadOfCrashing() {
        let counters: [UInt64: MonitorIOCount] = [1: MonitorIOCount(input: .max, output: 1), 2: MonitorIOCount(input: 2, output: 2)]
        let totals = MonitorMath.totals(counters)
        #expect(totals.input == 1)
        #expect(totals.output == 3)
    }

    /// Monta a saída de NET_RT_IFLIST2 à mão: cabeçalho `if_msghdr2` + `sockaddr_dl` com o nome.
    private func message(name: String, rx: UInt64, tx: UInt64, loopback: Bool = false) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        var link: [UInt8] = [0, UInt8(AF_LINK), 1, 0, 6, UInt8(nameBytes.count), 0, 0] + nameBytes
        link += [UInt8](repeating: 0, count: max(0, 20 - link.count))
        link[0] = UInt8(link.count)
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size + link.count)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_addrs = RTA_IFP
        header.ifm_flags = loopback ? IFF_LOOPBACK | IFF_UP : IFF_UP
        header.ifm_data.ifi_ibytes = rx
        header.ifm_data.ifi_obytes = tx
        return withUnsafeBytes(of: &header) { Array($0) } + link
    }

    @Test func parsesInterfaceListAndKeepsOnlyPhysicalInterfaces() {
        var buffer = message(name: "en0", rx: 1_000, tx: 2_000)
        buffer += message(name: "lo0", rx: 50, tx: 50, loopback: true)
        buffer += message(name: "utun4", rx: 900, tx: 900)
        buffer += message(name: "pdp_ip0", rx: 7, tx: 8)
        let counters = buffer.withUnsafeBytes { MonitorSystem.parseInterfaceList($0) }
        #expect(counters.count == 2)
        #expect(counters["en0"] == MonitorIOCount(input: 1_000, output: 2_000))
        #expect(counters["pdp_ip0"] == MonitorIOCount(input: 7, output: 8))
    }

    @Test func truncatedInterfaceListStopsSafely() {
        let buffer = message(name: "en0", rx: 1, tx: 1)
        let counters = buffer.withUnsafeBytes { MonitorSystem.parseInterfaceList(UnsafeRawBufferPointer(rebasing: $0[..<($0.count - 4)])) }
        #expect(counters.isEmpty)
        #expect([UInt8]().withUnsafeBytes { MonitorSystem.parseInterfaceList($0) }.isEmpty)
    }

    @Test func realCountersAreReadable() throws {
        var buffer: [UInt8] = []
        let net = try #require(MonitorSystem.networkCounters(buffer: &buffer))
        #expect(net.keys.allSatisfy(MonitorMath.isCountedInterface))
        #expect(MonitorSystem.diskCounters() != nil)
    }
}

@Suite("Monitor · Encerrar apps")
struct MonitorTerminationTests {
    let own: Int32 = 999

    @Test func regularUserAppsCanBeTerminated() {
        #expect(MonitorTerminationPolicy.canTerminate(pid: 500, bundlePath: "/Applications/Safari.app",
                                                      bundleIdentifier: "com.apple.Safari", isRegularApp: true, ownPID: own))
        #expect(MonitorTerminationPolicy.canTerminate(pid: 501, bundlePath: "/System/Applications/Notes.app",
                                                      bundleIdentifier: "com.apple.Notes", isRegularApp: true, ownPID: own))
        #expect(MonitorTerminationPolicy.canTerminate(pid: 502, bundlePath: "/Users/x/Applications/Foo.app",
                                                      bundleIdentifier: nil, isRegularApp: true, ownPID: own))
    }

    @Test func systemAndBackgroundProcessesAreProtected() {
        // Finder e afins: caminho de sistema e/ou identificador protegido.
        #expect(!MonitorTerminationPolicy.canTerminate(pid: 400, bundlePath: "/System/Library/CoreServices/Finder.app",
                                                       bundleIdentifier: "com.apple.finder", isRegularApp: true, ownPID: own))
        #expect(!MonitorTerminationPolicy.canTerminate(pid: 401, bundlePath: "/Applications/Fake.app",
                                                       bundleIdentifier: "com.apple.dock", isRegularApp: true, ownPID: own))
        // Agentes sem janela, processos sem pacote, o próprio app, launchd.
        #expect(!MonitorTerminationPolicy.canTerminate(pid: 402, bundlePath: "/Applications/Agent.app",
                                                       bundleIdentifier: nil, isRegularApp: false, ownPID: own))
        #expect(!MonitorTerminationPolicy.canTerminate(pid: 403, bundlePath: nil, bundleIdentifier: nil, isRegularApp: true, ownPID: own))
        #expect(!MonitorTerminationPolicy.canTerminate(pid: 404, bundlePath: "/usr/libexec/thing", bundleIdentifier: nil,
                                                       isRegularApp: true, ownPID: own))
        #expect(!MonitorTerminationPolicy.canTerminate(pid: own, bundlePath: "/Applications/CleanerCRTV.app",
                                                       bundleIdentifier: nil, isRegularApp: true, ownPID: own))
        #expect(!MonitorTerminationPolicy.canTerminate(pid: 1, bundlePath: "/Applications/X.app", bundleIdentifier: nil,
                                                       isRegularApp: true, ownPID: own))
    }

    @Test func systemBundles() {
        #expect(MonitorTerminationPolicy.isSystemBundle("/System/Library/CoreServices/Dock.app"))
        #expect(!MonitorTerminationPolicy.isSystemBundle("/Applications/Safari.app"))
    }
}
