import Foundation
import Testing
@testable import CleanerCore

// Nenhum teste aqui roda launchctl, AppleScript ou comando de administrador de verdade.

private func plistData(_ dict: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
}

private let fakeURL = URL(fileURLWithPath: "/Users/teste/Library/LaunchAgents/com.exemplo.agente.plist")

@Suite("Otimização: .plist do launchd")
struct OptimizePlistTests {
    @Test func programWinsOverProgramArguments() throws {
        let data = try plistData(["Label": "com.exemplo.a", "Program": "/usr/bin/true",
                                  "ProgramArguments": ["/bin/echo", "oi"]])
        let agent = OptimizeLaunchPlist.parse(data, url: fakeURL, scope: .user) { _ in false }
        #expect(agent.label == "com.exemplo.a")
        #expect(agent.program == "/usr/bin/true")
        #expect(agent.arguments == ["/bin/echo", "oi"])
        #expect(!agent.isBroken)
    }

    @Test func programArgumentsFirstIsTheProgram() throws {
        let data = try plistData(["Label": "com.exemplo.b", "ProgramArguments": ["/opt/x/bin/servidor", "serve"]])
        let agent = OptimizeLaunchPlist.parse(data, url: fakeURL, scope: .user) { _ in false }
        #expect(agent.program == "/opt/x/bin/servidor")
    }

    @Test func bundleProgramIsUsedAndNotChecked() throws {
        let data = try plistData(["Label": "com.exemplo.c", "BundleProgram": "Contents/MacOS/Helper"])
        let agent = OptimizeLaunchPlist.parse(data, url: fakeURL, scope: .user) { _ in true }
        #expect(agent.program == "Contents/MacOS/Helper")
        #expect(!agent.isBroken, "caminho relativo não dá para conferir")
    }

    @Test func missingProgramIsBroken() throws {
        let missing = "/Applications/App Que Sumiu \(UUID().uuidString).app/Contents/MacOS/Helper"
        let data = try plistData(["Label": "com.exemplo.d", "ProgramArguments": [missing, "--wake"]])
        let agent = OptimizeLaunchPlist.parse(data, url: fakeURL, scope: .user)
        #expect(agent.problem == .missingProgram(missing))
        #expect(agent.isBroken)
    }

    @Test func existingProgramIsNotBroken() throws {
        let data = try plistData(["Label": "com.exemplo.e", "Program": "/bin/sh"])
        #expect(!OptimizeLaunchPlist.parse(data, url: fakeURL, scope: .user).isBroken)
        let relative = try plistData(["Label": "com.exemplo.f", "ProgramArguments": ["sh", "-c", "true"]])
        #expect(!OptimizeLaunchPlist.parse(relative, url: fakeURL, scope: .user).isBroken)
    }

    @Test func pathIsMissingOnlyForReallyMissing() {
        #expect(!OptimizeLaunchPlist.pathIsMissing("/bin/sh"))
        #expect(OptimizeLaunchPlist.pathIsMissing("/nao-existe-\(UUID().uuidString)/programa"))
        // Volume desconectado: não acusa quebrado.
        #expect(!OptimizeLaunchPlist.pathIsMissing("/Volumes/Disco-\(UUID().uuidString)/app/bin"))
    }

    @Test func disabledKeyAndFlags() throws {
        let data = try plistData(["Label": "com.exemplo.g", "Program": "/bin/sh", "Disabled": true, "RunAtLoad": true,
                                  "KeepAlive": ["SuccessfulExit": false], "StartInterval": 3600,
                                  "AssociatedBundleIdentifiers": "com.exemplo.App"])
        var agent = OptimizeLaunchPlist.parse(data, url: fakeURL, scope: .user)
        #expect(agent.disabledInPlist)
        #expect(agent.isDisabled)
        #expect(agent.runAtLoad)
        #expect(agent.keepAlive == .conditional)
        #expect(agent.startInterval == 3600)
        #expect(agent.associatedBundleIDs == ["com.exemplo.App"])
        // A decisão do launchctl vale mais que a chave do arquivo.
        agent.disabledOverride = false
        #expect(agent.isEnabled)
    }

    @Test func invalidPlists() throws {
        let garbage = OptimizeLaunchPlist.parse(Data("isso não é plist".utf8), url: fakeURL, scope: .user)
        #expect(garbage.problem == .invalidPlist)
        #expect(garbage.label == "com.exemplo.agente")
        let noLabel = OptimizeLaunchPlist.parse(try plistData(["Program": "/bin/sh"]), url: fakeURL, scope: .user)
        #expect(noLabel.problem == .invalidPlist)
        let noProgram = OptimizeLaunchPlist.parse(try plistData(["Label": "com.exemplo.h"]), url: fakeURL, scope: .user)
        #expect(noProgram.problem == .invalidPlist)
        #expect(!noProgram.isManageable)
    }

    @Test func calendarAndSchedule() throws {
        let daily = try plistData(["Label": "a", "Program": "/bin/sh", "StartCalendarInterval": ["Hour": 19, "Minute": 55]])
        #expect(OptimizeLaunchPlist.parse(daily, url: fakeURL, scope: .user).scheduleDescription == "Todo dia às 19:55")

        let weekly = try plistData(["Label": "a", "Program": "/bin/sh", "StartCalendarInterval": [["Weekday": 1, "Hour": 9]]])
        #expect(OptimizeLaunchPlist.parse(weekly, url: fakeURL, scope: .user).scheduleDescription == "Toda segunda às 09:00")

        let many = try plistData(["Label": "a", "Program": "/bin/sh", "StartCalendarInterval": [["Hour": 1], ["Hour": 13]]])
        #expect(OptimizeLaunchPlist.parse(many, url: fakeURL, scope: .user).calendarIntervals.count == 2)

        let login = try plistData(["Label": "a", "Program": "/bin/sh", "RunAtLoad": true, "KeepAlive": true])
        #expect(OptimizeLaunchPlist.parse(login, url: fakeURL, scope: .user).scheduleDescription == "Ao iniciar sessão · Sempre ativo")

        let idle = try plistData(["Label": "a", "Program": "/bin/sh"])
        #expect(OptimizeLaunchPlist.parse(idle, url: fakeURL, scope: .user).scheduleDescription == "Sob demanda")

        #expect(OptimizeLaunchAgent.describeInterval(3600) == "A cada 1 h")
        #expect(OptimizeLaunchAgent.describeInterval(300) == "A cada 5 min")
        #expect(OptimizeLaunchAgent.describeInterval(86_400) == "Uma vez por dia")
        #expect(OptimizeLaunchAgent.describeInterval(172_800) == "A cada 2 dias")
        #expect(OptimizeLaunchAgent.describeCalendar([OptimizeCalendarInterval(weekday: 7)]) == "Todo domingo")
    }
}

@Suite("Otimização: saídas do launchctl")
struct OptimizeLaunchctlParserTests {
    @Test func parsesList() {
        let output = """
        PID\tStatus\tLabel
        -\t0\tcom.apple.SafariHistoryServiceAgent
        96040\t-15\tcom.apple.Finder
        1349\t0\tsh.brew.ollama
        -\t111\tcom.adobe.ARMDCHelper.cc24
        """
        let list = OptimizeLaunchctlParser.parseList(output)
        #expect(list.count == 4)
        #expect(list["sh.brew.ollama"] == OptimizeServiceStatus(pid: 1349, lastExitStatus: 0))
        #expect(list["com.apple.Finder"]?.lastExitStatus == -15)
        #expect(list["com.apple.SafariHistoryServiceAgent"]?.pid == nil)
        #expect(list["com.adobe.ARMDCHelper.cc24"]?.lastExitStatus == 111)
        #expect(list["Label"] == nil)
    }

    @Test func parsesDisabledBothFormats() {
        let modern = """
        \tdisabled services = {
        \t\t"com.adobe.GC.AGM" => disabled
        \t\t"com.ulanzi.UlanziDeck" => enabled
        \t\t"sh.brew.ollama" => enabled
        \t}
        """
        let parsed = OptimizeLaunchctlParser.parseDisabled(modern)
        #expect(parsed == ["com.adobe.GC.AGM": true, "com.ulanzi.UlanziDeck": false, "sh.brew.ollama": false])

        let legacy = """
        disabled services = {
            "com.foo.bar" => true
            "com.foo.baz" => false
        }
        """
        #expect(OptimizeLaunchctlParser.parseDisabled(legacy) == ["com.foo.bar": true, "com.foo.baz": false])
    }

    @Test func parsesDomainServicesBlock() {
        let output = """
        system = {
        \ttype = system
        \tservices = {
        \t\t       0      - \tcom.apple.backgroundassets.managed.relay.service
        \t\t     720      - \tcom.apple.bcmwlan-0x100000f60
        \t\t       0   (pe) \tcom.apple.lskdd
        \t\t       0      1 \tcom.apple.wifiFirmwareLoader
        \t\t     541      - \tcom.macpaw.CleanMyMac5.Agent
        \t}

        \tdisabled services = {
        \t\t"com.apple.ftpd" => disabled
        \t}
        }
        """
        let services = OptimizeLaunchctlParser.parseDomainServices(output)
        #expect(services.count == 5)
        #expect(services["com.macpaw.CleanMyMac5.Agent"]?.pid == 541)
        #expect(services["com.apple.lskdd"] == OptimizeServiceStatus(pid: nil, lastExitStatus: nil))
        #expect(services["com.apple.wifiFirmwareLoader"]?.lastExitStatus == 1)
        #expect(services["com.apple.ftpd"] == nil, "o bloco de desativados não entra")
    }

    @Test func parsesServicePath() {
        let output = """
        gui/501/com.ulanzi.UlanziDeck = {
        \tactive count = 0
        \tpath = /Users/teste/Library/LaunchAgents/com.ulanzi.UlanziDeck.plist
        \ttype = LaunchAgent
        \tstate = not running
        }
        """
        #expect(OptimizeLaunchctlParser.parseServicePath(output) == "/Users/teste/Library/LaunchAgents/com.ulanzi.UlanziDeck.plist")
        #expect(OptimizeLaunchctlParser.parseServicePath("type = LaunchAgent") == nil)
    }

    @Test func stopsOnlyTheServiceLoadedFromThisPlist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("optimize-same-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("com.exemplo.a.plist")
        try Data("x".utf8).write(to: plist)
        let link = dir.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plist)

        #expect(OptimizeLaunchctl.isSamePlist(loadedFrom: nil, plist: plist), "sem linha path: bootout como antes")
        #expect(OptimizeLaunchctl.isSamePlist(loadedFrom: plist.path, plist: plist))
        #expect(OptimizeLaunchctl.isSamePlist(loadedFrom: link.path, plist: plist), "link e destino são o mesmo arquivo")
        #expect(!OptimizeLaunchctl.isSamePlist(loadedFrom: "/Library/LaunchAgents/com.exemplo.a.plist", plist: plist),
                "mesmo rótulo em /Library não cai junto")
    }

    @Test func stopRefusesInvalidLabelWithoutRunningAnything() async {
        #expect(await OptimizeLaunchctl.stopIfLoaded(from: fakeURL, label: "a/b") == false)
        #expect(await OptimizeLaunchctl.stopIfLoaded(from: fakeURL, label: "") == false)
    }

    @Test func commandsUseServiceTargets() {
        let disable = OptimizeLaunchctl.disableCommands(label: "com.exemplo.a", uid: 501)
        #expect(disable == [["bootout", "gui/501/com.exemplo.a"], ["disable", "gui/501/com.exemplo.a"]])
        let plist = URL(fileURLWithPath: "/Users/teste/Library/LaunchAgents/com.exemplo.a.plist")
        let enable = OptimizeLaunchctl.enableCommands(label: "com.exemplo.a", plist: plist, uid: 501)
        #expect(enable == [["enable", "gui/501/com.exemplo.a"], ["bootstrap", "gui/501", plist.path]])
    }

    @Test func labelValidation() {
        #expect(OptimizeLaunchctl.isValidLabel("com.exemplo.agente-1.0"))
        #expect(!OptimizeLaunchctl.isValidLabel(""))
        #expect(!OptimizeLaunchctl.isValidLabel("a/b"))
        #expect(!OptimizeLaunchctl.isValidLabel("-h"))
        #expect(!OptimizeLaunchctl.isValidLabel("linha\nquebrada"))
    }

    @Test func systemAgentsAreRefused() async {
        let agent = OptimizeLaunchAgent(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist"),
                                        scope: .systemDaemon, label: "com.x", program: "/bin/sh")
        #expect(!agent.isManageable)
        // Recusa antes de rodar qualquer processo.
        #expect(await OptimizeLaunchctl.disable(agent) == .refused)
        #expect(await OptimizeLaunchctl.enable(agent) == .refused)
    }

    @Test func reloadRefusesWhatItCannotManage() async {
        let daemon = OptimizeLaunchAgent(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist"),
                                         scope: .systemDaemon, label: "com.x", program: "/bin/sh")
        #expect(await OptimizeLaunchctl.reload(daemon) == .refused)
        let invalid = OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "com.exemplo.agente", problem: .invalidPlist)
        #expect(await OptimizeLaunchctl.reload(invalid) == .refused)
        #expect(await OptimizeLaunchctl.bootout(label: "a/b") == .refused)
    }

    @Test func notLoadedStatusesAreBenign() {
        #expect(OptimizeLaunchctl.isNotLoadedStatus(OptimizeProcessResult(status: 113)))
        #expect(OptimizeLaunchctl.isNotLoadedStatus(OptimizeProcessResult(status: 3)))
        #expect(!OptimizeLaunchctl.isNotLoadedStatus(OptimizeProcessResult(status: 5)))
        #expect(!OptimizeLaunchctl.isNotLoadedStatus(OptimizeProcessResult(status: 113, timedOut: true)))
    }
}

@Suite("Otimização: inventário")
struct OptimizeInventoryTests {
    @Test func readsOnlyPlistsAndMarksRemovable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("optimize-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try plistData(["Label": "com.exemplo.ok", "Program": "/bin/sh"]).write(to: dir.appendingPathComponent("com.exemplo.ok.plist"))
        try plistData(["Label": "com.exemplo.quebrado", "Program": "/nao/existe/\(UUID().uuidString)"])
            .write(to: dir.appendingPathComponent("com.exemplo.quebrado.plist"))
        try plistData(["Label": "com.exemplo.ignorado", "Program": "/bin/sh"]).write(to: dir.appendingPathComponent("ignorado.plist"))
        try Data("texto".utf8).write(to: dir.appendingPathComponent("leia-me.txt"))

        let source = OptimizeAgentSource(directory: dir, scope: .user)
        let agents = OptimizeAgentScanner.readAgents(
            in: [source],
            isExcluded: { $0.lastPathComponent == "ignorado.plist" },
            isSafeToRemove: { _ in true }
        )
        #expect(agents.map(\.label).sorted() == ["com.exemplo.ok", "com.exemplo.quebrado"])
        #expect(agents.allSatisfy { $0.isRemovable })
        #expect(agents.first { $0.label == "com.exemplo.quebrado" }?.isBroken == true)

        // A pasta temporária fica fora das áreas liberadas: o SafetyGuard real não deixa remover.
        let guarded = OptimizeAgentScanner.readAgents(in: [source], isExcluded: { _ in false })
        #expect(guarded.allSatisfy { !$0.isRemovable })

        let system = OptimizeAgentScanner.readAgents(in: [OptimizeAgentSource(directory: dir, scope: .systemAgent)],
                                                     isSafeToRemove: { _ in true })
        #expect(system.allSatisfy { !$0.isRemovable }, "de /Library nunca é removível")
    }

    @Test func userAgentInsideHomeIsRemovable() throws {
        let dir = Paths.home.appendingPathComponent(".cleanercrtv-optimize-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try plistData(["Label": "com.exemplo.casa", "Program": "/bin/sh"]).write(to: dir.appendingPathComponent("com.exemplo.casa.plist"))
        let agents = OptimizeAgentScanner.readAgents(in: [OptimizeAgentSource(directory: dir, scope: .user)], isExcluded: { _ in false })
        #expect(agents.count == 1)
        #expect(agents[0].isRemovable)
    }

    @Test func appliesRuntimeSnapshot() {
        let user = OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "com.u", program: "/bin/sh", disabledInPlist: true)
        let shared = OptimizeLaunchAgent(url: URL(fileURLWithPath: "/Library/LaunchAgents/com.s.plist"), scope: .systemAgent,
                                         label: "com.s", program: "/bin/sh")
        let daemon = OptimizeLaunchAgent(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.d.plist"), scope: .systemDaemon,
                                         label: "com.d", program: "/bin/sh")
        let snapshot = OptimizeRuntimeSnapshot(
            userServices: ["com.u": OptimizeServiceStatus(pid: 42, lastExitStatus: 0), "com.s": OptimizeServiceStatus()],
            userDisabled: ["com.u": false],
            systemServices: ["com.u": OptimizeServiceStatus(pid: 1)],
            systemDisabled: ["com.d": true]
        )
        let result = OptimizeAgentScanner.apply(snapshot, to: [user, shared, daemon])
        #expect(result[0].isLoaded && result[0].pid == 42 && result[0].isEnabled)
        #expect(result[1].isLoaded && !result[1].isRunning)
        #expect(!result[2].isLoaded && result[2].isDisabled)
    }

    @Test func ownerGuesses() {
        var agents = [
            OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "com.google.GoogleUpdater.wake", program: "/bin/x",
                                associatedBundleIDs: ["com.google.GoogleUpdater"]),
            OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "com.ulanzi.UlanziDeck",
                                program: "/Applications/Ulanzi Studio.app/Contents/Library/Helper.app/Contents/MacOS/UlanziDeck"),
            OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "com.spotify.client.startuphelper", program: "/bin/x"),
            OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "com.desconhecido.coisa", program: "/bin/x"),
        ]
        let apps = [
            "com.google.GoogleUpdater": URL(fileURLWithPath: "/Applications/GoogleUpdater.app"),
            "com.spotify.client": URL(fileURLWithPath: "/Applications/Spotify.app"),
        ]
        OptimizeAgentScanner.resolveOwners(&agents, lookup: { apps[$0] }, exists: { $0 == "/Applications/Ulanzi Studio.app" })
        #expect(agents[0].owner?.url.path == "/Applications/GoogleUpdater.app")
        #expect(agents[1].owner?.url.path == "/Applications/Ulanzi Studio.app")
        #expect(agents[2].owner?.url.path == "/Applications/Spotify.app")
        #expect(agents[3].owner == nil)
        #expect(agents[3].displayName == "com.desconhecido.coisa")
    }

    @Test func searchMatchesNameLabelAndProgram() {
        var agent = OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "com.spotify.client.startuphelper",
                                        program: "/Applications/Spotify.app/Contents/Library/Helper")
        agent.owner = OptimizeOwnerApp(name: "Música Spotify", url: URL(fileURLWithPath: "/Applications/Spotify.app"))
        #expect(agent.matches(""))
        #expect(agent.matches("  "))
        #expect(agent.matches("SPOTIFY"))
        #expect(agent.matches("musica"), "ignora acentos")
        #expect(agent.matches("startuphelper"))
        #expect(agent.matches("Contents/Library"))
        #expect(agent.matches("com.exemplo.agente.plist"))
        #expect(!agent.matches("dropbox"))
    }

    @Test func helpers() {
        #expect(OptimizeAgentScanner.appBundlePath(in: "/Applications/A.app/Contents/B.app/Contents/MacOS/b") == "/Applications/A.app")
        #expect(OptimizeAgentScanner.appBundlePath(in: "/usr/local/bin/x") == nil)
        #expect(OptimizeAgentScanner.labelPrefixes("com.a.b.c") == ["com.a.b.c", "com.a.b", "com.a"])
        #expect(OptimizeAgentScanner.labelPrefixes("solo").isEmpty)
    }

    @Test func sortsUserFirstAndBrokenOnTop() {
        let ok = OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "a.ok", program: "/bin/sh")
        let broken = OptimizeLaunchAgent(url: fakeURL, scope: .user, label: "z.broken", program: "/x", problem: .missingProgram("/x"))
        let system = OptimizeLaunchAgent(url: fakeURL, scope: .systemDaemon, label: "0.sys", program: "/bin/sh")
        #expect(OptimizeAgentScanner.sorted([system, ok, broken]).map(\.label) == ["z.broken", "a.ok", "0.sys"])
    }
}

@Suite("Otimização: manutenção")
struct OptimizeMaintenanceTests {
    @Test func catalogSanity() {
        let all = OptimizeMaintenanceCatalog.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.count == 7)
        for task in all {
            #expect(!task.title.isEmpty && !task.explanation.isEmpty)
            for step in task.steps {
                #expect(step.executable.hasPrefix("/"), "\(task.id): \(step.executable) precisa ser absoluto")
                #expect(FileManager.default.isExecutableFile(atPath: step.executable), "\(step.executable) não existe")
            }
            switch task.privilege {
            case .user: #expect(!task.steps.isEmpty && task.adminCommand == nil)
            case .admin: #expect(task.steps.isEmpty && task.adminCommand != nil)
            case .userThenAdmin: #expect(!task.steps.isEmpty && task.adminCommand != nil)
            }
        }
    }

    @Test func adminFlags() {
        let admin = Set(OptimizeMaintenanceCatalog.all.filter(\.needsPassword).map(\.id))
        #expect(admin == ["freeMemory", "flushDNS", "reindexSpotlight"])
        #expect(OptimizeMaintenanceCatalog.verifyDisk.privilege == .userThenAdmin)
        #expect(OptimizeMaintenanceCatalog.restartFinderDock.needsConfirmation)
        #expect(OptimizeMaintenanceCatalog.reindexSpotlight.warning != nil)
    }

    @Test func adminCommandsAreFixedAbsolutePaths() {
        for task in OptimizeMaintenanceCatalog.all {
            guard let command = task.adminCommand else { continue }
            // Nada de aspas, crase, $ ou barra invertida: a linha é fixa e não abre espaço para injeção.
            #expect(!command.contains { "\"'`$\\".contains($0) }, "\(task.id)")
            let segments = command
                .replacingOccurrences(of: "||", with: ";")
                .replacingOccurrences(of: "&&", with: ";")
                .split(separator: ";")
            for segment in segments {
                let executable = segment.split(separator: " ").first.map(String.init) ?? ""
                if executable == "true" { continue }
                #expect(executable.hasPrefix("/"), "\(task.id): \(executable)")
                #expect(FileManager.default.isExecutableFile(atPath: executable), "\(executable) não existe")
            }
        }
    }

    @Test func appleScriptLiteralEscapes() {
        #expect(OptimizeAppleScript.literal(#"a "b" \c"#) == #""a \"b\" \\c""#)
        #expect(OptimizeAppleScript.fourCharCode("ascr") == 0x6173_6372)
    }

    @Test func subroutineEventCarriesArgumentsAsData() {
        let event = OptimizeAppleScript.subroutineEvent(handler: "removeLoginItem", arguments: [#"Nome "estranho""#, "/Applications/A.app"])
        #expect(event.paramDescriptor(forKeyword: OptimizeAppleScript.fourCharCode("snam"))?.stringValue == "removeloginitem")
        let list = event.paramDescriptor(forKeyword: OptimizeAppleScript.fourCharCode("----"))
        #expect(list?.numberOfItems == 2)
        #expect(list?.atIndex(1)?.stringValue == #"Nome "estranho""#)
    }

    @Test func maintenanceLogPersists() throws {
        let suite = "optimize-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = OptimizeMaintenanceLog(defaults: defaults)
        #expect(log.lastRun("flushDNS") == nil)
        log.record("flushDNS", outcome: OptimizeTaskOutcome(status: .cancelled, message: "x"))
        #expect(log.lastRun("flushDNS") == nil, "cancelado não conta como executado")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        log.record("flushDNS", outcome: OptimizeTaskOutcome(status: .success, message: "Cache de DNS limpo.", date: date))
        #expect(log.lastRun("flushDNS") == date)
        #expect(log.lastMessage("flushDNS") == "Cache de DNS limpo.")
    }

    @Test func memoryReading() {
        #expect((OptimizeMemory.freeBytes() ?? 0) > 0)
    }
}

@Suite("Otimização: verificação do disco")
struct OptimizeDiskVerifyTests {
    let healthy = """
    Started file system verification on disk3s1s1 (Macintosh HD)
    Verifying file system
    Performing fsck_apfs -n -x -l -S /dev/rdisk3s1s1
    Checking the container superblock
    warning: Overallocation Detected on Main device
    The volume /dev/rdisk3s1s1 with UUID 4A43 appears to be OK
    File system check exit code is 0
    Finished file system verification on disk3s1s1 (Macintosh HD)
    """

    @Test func healthyWithWarning() {
        let verdict = OptimizeDiskVerify.verdict(output: healthy, exitCode: 0)
        #expect(verdict == .ok(warnings: 1))
        #expect(OptimizeDiskVerify.volumeName(in: healthy) == "Macintosh HD")
        #expect(OptimizeDiskVerify.message(for: verdict, volume: "Macintosh HD").hasPrefix("Macintosh HD: sem erros"))
    }

    @Test func problemsFound() {
        let output = """
        Started file system verification on disk3s5 (Data)
        error: directory valence check: directory (oid 0x1d): nchildren (2) does not match drec count (0)
        The volume /dev/rdisk3s5 was found to be corrupt and needs to be repaired
        File system check exit code is 8
        Error: -69845: File system verify or repair failed
        """
        #expect(OptimizeDiskVerify.verdict(output: output, exitCode: 1) == .problems)
    }

    @Test func couldNotVerify() {
        let output = "Error: -69888: This operation requires root privileges"
        let verdict = OptimizeDiskVerify.verdict(output: output, exitCode: 1)
        #expect(verdict == .couldNotVerify("Error: -69888: This operation requires root privileges"))
        #expect(OptimizeDiskVerify.message(for: verdict, volume: nil).hasPrefix("Não foi possível verificar"))
    }

    @Test func outcomeOffersAdminRetryOnlyWhenItCouldNotVerify() {
        let task = OptimizeMaintenanceCatalog.verifyDisk
        let failed = OptimizeMaintenanceRunner.finish(task, output: "Error: -69888: requires root", exitCode: 1, freeBefore: nil, ranAsAdmin: false)
        #expect(failed.status == .failure && failed.canRetryAsAdmin)
        let asAdmin = OptimizeMaintenanceRunner.finish(task, output: "Error: -69888: requires root", exitCode: 0, freeBefore: nil, ranAsAdmin: true)
        #expect(!asAdmin.canRetryAsAdmin)
        let ok = OptimizeMaintenanceRunner.finish(task, output: healthy, exitCode: 0, freeBefore: nil, ranAsAdmin: false)
        #expect(ok.status == .warning && !ok.canRetryAsAdmin && ok.details != nil)
    }

    @Test func tailKeepsTheEnd() {
        let output = (1...100).map(String.init).joined(separator: "\n")
        #expect(OptimizeDiskVerify.tail(output, lines: 3) == "98\n99\n100")
    }
}

@Suite("Otimização: itens de início")
struct OptimizeLoginItemsTests {
    @Test func zipsColumns() {
        let items = OptimizeLoginItems.items(names: ["Zoom", "", "Alfa"],
                                             paths: ["/Applications/zoom.us.app", "/Applications/Beta.app", nil],
                                             hidden: [false, true])
        #expect(items.map(\.name) == ["Alfa", "Beta", "Zoom"])
        #expect(items[0].path == nil && items[0].url == nil)
        #expect(items[1].isHidden)
        #expect(items[2].url?.path == "/Applications/zoom.us.app")
    }

    @Test func readsAppleEventColumns() {
        let names = NSAppleEventDescriptor.list()
        names.insert(NSAppleEventDescriptor(string: "Dropbox"), at: 1)
        names.insert(NSAppleEventDescriptor(string: "Sem caminho"), at: 2)
        let paths = NSAppleEventDescriptor.list()
        paths.insert(NSAppleEventDescriptor(string: "/Applications/Dropbox.app"), at: 1)
        paths.insert(NSAppleEventDescriptor(typeCode: OptimizeAppleScript.fourCharCode("msng")), at: 2)
        let hidden = NSAppleEventDescriptor.list()
        hidden.insert(NSAppleEventDescriptor(boolean: true), at: 1)
        hidden.insert(NSAppleEventDescriptor(boolean: false), at: 2)
        let result = NSAppleEventDescriptor.list()
        result.insert(names, at: 1)
        result.insert(paths, at: 2)
        result.insert(hidden, at: 3)

        let columns = OptimizeLoginItems.columns(from: result)
        #expect(columns.names == ["Dropbox", "Sem caminho"])
        #expect(columns.paths == ["/Applications/Dropbox.app", nil])
        #expect(columns.hidden == [true, false])
    }

    @Test func emptyResult() {
        let empty = NSAppleEventDescriptor.list()
        for index in 1...3 { empty.insert(NSAppleEventDescriptor.list(), at: index) }
        let columns = OptimizeLoginItems.columns(from: empty)
        #expect(columns.names.isEmpty && columns.paths.isEmpty)
    }

    @Test func errorMapping() {
        #expect(OptimizeLoginItemsError(OptimizeScriptError(code: -1743, message: "")) == .notPermitted)
        #expect(OptimizeLoginItemsError(OptimizeScriptError(code: -128, message: "")) == .cancelled)
        #expect(OptimizeLoginItemsError(OptimizeScriptError(code: -1712, message: "")) == .timeout)
        #expect(OptimizeLoginItemsError(OptimizeScriptError(code: -10000, message: "falhou")) == .failed("falhou"))
    }
}

@Suite("Otimização: processos")
struct OptimizeProcessTests {
    @Test func capturesOutputAndStatus() async {
        let ok = await OptimizeProcess.run("/bin/echo", ["olá", "mundo"])
        #expect(ok.succeeded)
        #expect(ok.stdout == "olá mundo\n")
        let fail = await OptimizeProcess.run("/bin/ls", ["/nao-existe-\(UUID().uuidString)"])
        #expect(!fail.succeeded && fail.status != 0 && !fail.stderr.isEmpty)
    }

    @Test func argumentsAreNotInterpretedByAShell() async {
        let result = await OptimizeProcess.run("/bin/echo", ["$HOME; rm -rf /tmp/x"])
        #expect(result.stdout == "$HOME; rm -rf /tmp/x\n")
    }

    @Test func timesOut() async {
        let started = Date()
        let result = await OptimizeProcess.run("/bin/sleep", ["5"], timeout: 0.3)
        #expect(result.timedOut && !result.succeeded)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func cancels() async {
        let task = Task { await OptimizeProcess.run("/bin/sleep", ["5"], timeout: 10) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        #expect(result.cancelled && !result.succeeded)
    }

    @Test func rejectsRelativeExecutable() async {
        let result = await OptimizeProcess.run("echo", ["x"])
        #expect(result.launchError != nil)
    }

    @Test func largeOutputDoesNotDeadlock() async {
        // Mais que o buffer de um pipe (64 KB) nas duas saídas.
        let result = await OptimizeProcess.run("/bin/sh", ["-c", "yes a | head -c 300000; yes b | head -c 300000 >&2"])
        #expect(result.succeeded)
        #expect(result.stdout.count == 300_000 && result.stderr.count == 300_000)
    }
}
