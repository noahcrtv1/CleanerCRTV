import Foundation
import Testing
@testable import CleanerCore

/// Árvore de arquivos descartável para os testes (nunca toca nos arquivos do usuário).
private final class UninstallFakeTree {
    let root: URL

    init(underHome: Bool = false) throws {
        let base = underHome ? Paths.home : FileManager.default.temporaryDirectory
        root = base.appendingPathComponent(".cleanercrtv-test-uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var library: URL { root.appendingPathComponent("Library", isDirectory: true) }

    func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }

    @discardableResult
    func dir(_ rel: String) throws -> URL {
        let u = url(rel)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 10) throws -> URL {
        let u = url(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: u)
        return u
    }

    @discardableResult
    func plist(_ rel: String, _ dict: [String: Any]) throws -> URL {
        let u = url(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: u)
        return u
    }

    /// Data de modificação de tudo dentro de `rel` (filhos antes, a pasta por último).
    func age(_ rel: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        let target = url(rel)
        let fm = FileManager.default
        if let walker = fm.enumerator(at: target, includingPropertiesForKeys: nil) {
            for case let child as URL in walker { try fm.setAttributes([.modificationDate: date], ofItemAtPath: child.path) }
        }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
    }

    /// Envelhece todo o ~/Library falso.
    func ageLibrary(days: Double) throws {
        for location in UninstallLocation.allCases {
            let folder = library.appendingPathComponent(location.relativePath)
            for child in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try age("Library/\(location.relativePath)/\(child)", days: days)
            }
        }
    }
}

private let permissive = UninstallFilter(excluded: [], checksSafety: false)

private func app(_ id: String?, name: String, path: String = "/Applications", team: String? = nil,
                 embedded: [String] = [], aliases: [String] = []) -> UninstallApp {
    UninstallApp(url: URL(fileURLWithPath: "\(path)/\(name).app"), name: name, bundleID: id, teamID: team,
                 embeddedBundleIDs: embedded, aliases: aliases)
}

// MARK: - Identificadores

@Suite("Desinstalador: identificadores")
struct UninstallBundleIDTests {
    @Test func reverseDNS() {
        #expect(UninstallBundleID.looksLikeBundleID("com.foo.app"))
        #expect(UninstallBundleID.looksLikeBundleID("io.github.some-one.tool"))
        #expect(!UninstallBundleID.looksLikeBundleID("com.foo"))
        #expect(!UninstallBundleID.looksLikeBundleID("1.2.3"))
        #expect(!UninstallBundleID.looksLikeBundleID("spotify"))
        #expect(!UninstallBundleID.looksLikeBundleID("com..app"))
        #expect(!UninstallBundleID.looksLikeBundleID("com.foo.my app"))
    }

    @Test func childAndOwner() {
        #expect(UninstallBundleID.isSame("com.foo.app.helper", orChildOf: "com.foo.app"))
        #expect(!UninstallBundleID.isSame("com.foo.application", orChildOf: "com.foo.app"))
        #expect(UninstallBundleID.owner(of: "com.foo.app.pro.x", among: ["com.foo.app", "com.foo.app.pro"]) == "com.foo.app.pro")
        #expect(UninstallBundleID.vendor(of: "com.foo.app.helper") == "com.foo")
        #expect(UninstallBundleID.vendor(of: "io.github.fulano.tool") == "io.github.fulano")
    }

    @Test func parsesNamesPerFolder() {
        func key(_ name: String, _ location: UninstallLocation) -> String? {
            UninstallLibraryEntry(url: URL(fileURLWithPath: "/x/\(name)"), location: location).key
        }
        #expect(key("com.Foo.App.plist", .preferences) == "com.foo.app")
        #expect(key("com.foo.app", .preferences) == nil)
        #expect(key("com.foo.app.0F1A2B3C-1111-2222-3333-444455556666.plist", .byHost) == "com.foo.app")
        #expect(key("com.foo.app.savedState", .savedState) == "com.foo.app")
        #expect(key("com.foo.app.binarycookies", .cookies) == "com.foo.app")
        #expect(key("com.foo.app.binarycookies", .httpStorages) == "com.foo.app")
        #expect(key("com.foo.app", .httpStorages) == "com.foo.app")
        #expect(key("group.com.foo.app", .groupContainers) == "com.foo.app")
        let team = UninstallLibraryEntry(url: URL(fileURLWithPath: "/x/ABCDE12345.com.foo.app"), location: .groupContainers)
        #expect(team.key == "com.foo.app")
        #expect(team.teamPrefix == "ABCDE12345")
        #expect(key("group.com.foo.app", .caches) == "group.com.foo.app")
    }
}

// MARK: - Restos de um app instalado

@Suite("Desinstalador: restos de um app")
struct UninstallLeftoverTests {
    let notes = app("com.acme.notes", name: "Notes", team: "ABCDE12345",
                    embedded: ["com.acme.notes.ShareExtension", "org.sparkle-project.Sparkle"])
    let notesPro = app("com.acme.notes.pro", name: "Notes Pro")
    let editor = app("com.other.editor", name: "Editor")

    func buildTree() throws -> UninstallFakeTree {
        let t = try UninstallFakeTree()
        try t.file("Library/Preferences/com.acme.notes.plist")
        try t.file("Library/Preferences/com.acme.notes.helper.plist")
        try t.file("Library/Preferences/com.acme.notesextra.plist")
        try t.file("Library/Preferences/com.acme.notes.pro.plist")
        try t.file("Library/Preferences/ByHost/com.acme.notes.0F1A2B3C-1111-2222-3333-444455556666.plist")
        try t.file("Library/Caches/com.acme.notes/cache.db", bytes: 50_000)
        try t.file("Library/Caches/com.acme.notes.ShareExtension/x")
        try t.file("Library/Caches/org.sparkle-project.Sparkle/x")
        try t.file("Library/Containers/com.acme.notes/Data/x")
        try t.dir("Library/Group Containers/group.com.acme.notes")
        try t.dir("Library/Group Containers/ABCDE12345.com.acme.notes")
        try t.dir("Library/Group Containers/ZZZZZ99999.com.acme.notes")
        try t.dir("Library/Group Containers/ABCDE12345.shared")
        try t.dir("Library/Saved Application State/com.acme.notes.savedState")
        try t.file("Library/HTTPStorages/com.acme.notes.binarycookies")
        try t.file("Library/Cookies/com.acme.notes.binarycookies")
        try t.dir("Library/WebKit/com.acme.notes")
        try t.dir("Library/Application Scripts/com.acme.notes")
        try t.dir("Library/Application Support/Notes")
        try t.dir("Library/Application Support/NotesHelperXYZ")
        try t.dir("Library/Application Support/MyNotes")
        try t.dir("Library/Application Support/Notes 2")
        try t.dir("Library/Application Support/Notes Pro")
        try t.dir("Library/Caches/notes")
        try t.dir("Library/Logs/Notes")
        try t.plist("Library/LaunchAgents/acme-sync.plist", ["Label": "com.acme.notes.sync", "Program": "/nao/existe"])
        try t.plist("Library/LaunchAgents/runner.plist",
                    ["Label": "runner", "ProgramArguments": ["/Applications/Notes.app/Contents/MacOS/runner", "--bg"]])
        try t.plist("Library/LaunchAgents/com.other.thing.plist", ["Label": "com.other.thing", "Program": "/bin/ls"])
        return t
    }

    func matches(_ t: UninstallFakeTree) -> [String: UninstallConfidence] {
        let index = UninstallLibraryIndex.build(home: t.root)
        let found = UninstallLeftoverFinder.match(app: notes, in: index, installed: [notes, notesPro, editor])
        var map: [String: UninstallConfidence] = [:]
        for item in found {
            let rel = String(item.url.path.dropFirst(t.library.path.count + 1))
            map[rel] = item.confidence
        }
        return map
    }

    @Test func exactBundleIDAndHelpersAreHigh() throws {
        let t = try buildTree()
        let m = matches(t)
        let high = [
            "Preferences/com.acme.notes.plist", "Preferences/com.acme.notes.helper.plist",
            "Preferences/ByHost/com.acme.notes.0F1A2B3C-1111-2222-3333-444455556666.plist",
            "Caches/com.acme.notes", "Caches/com.acme.notes.ShareExtension", "Containers/com.acme.notes",
            "Group Containers/group.com.acme.notes", "Group Containers/ABCDE12345.com.acme.notes",
            "Saved Application State/com.acme.notes.savedState", "HTTPStorages/com.acme.notes.binarycookies",
            "Cookies/com.acme.notes.binarycookies", "WebKit/com.acme.notes", "Application Scripts/com.acme.notes",
            "LaunchAgents/acme-sync.plist", "LaunchAgents/runner.plist",
        ]
        for path in high { #expect(m[path] == .high, "esperava alta em \(path)") }
    }

    @Test func nameMatchIsMediumAndWholeNameOnly() throws {
        let t = try buildTree()
        let m = matches(t)
        #expect(m["Application Support/Notes"] == .medium)
        #expect(m["Caches/notes"] == .medium)
        #expect(m["Logs/Notes"] == .medium)
        for path in ["Application Support/NotesHelperXYZ", "Application Support/MyNotes",
                     "Application Support/Notes 2", "Application Support/Notes Pro"] {
            #expect(m[path] == nil, "não devia casar \(path)")
        }
    }

    @Test func neverSubstringOtherOwnersOrSharedLibraries() throws {
        let t = try buildTree()
        let m = matches(t)
        for path in ["Preferences/com.acme.notesextra.plist", "Preferences/com.acme.notes.pro.plist",
                     "Caches/org.sparkle-project.Sparkle", "Group Containers/ZZZZZ99999.com.acme.notes",
                     "Group Containers/ABCDE12345.shared", "LaunchAgents/com.other.thing.plist"] {
            #expect(m[path] == nil, "não devia casar \(path)")
        }
    }

    @Test func teamlessAppGetsMediumOnTeamPrefixedGroups() throws {
        let t = try UninstallFakeTree()
        try t.dir("Library/Group Containers/ABCDE12345.com.acme.notes")
        let unsigned = app("com.acme.notes", name: "Notes")
        let found = UninstallLeftoverFinder.match(app: unsigned, in: .build(home: t.root), installed: [unsigned])
        #expect(found.count == 1)
        #expect(found.first?.confidence == .medium)
    }

    @Test func defaultSelectionSparesUserData() {
        let url = URL(fileURLWithPath: "/x")
        #expect(UninstallLeftover(url: url, kind: .preferences, confidence: .high, ownerKey: "a").isSelectedByDefault)
        #expect(UninstallLeftover(url: url, kind: .caches, confidence: .high, ownerKey: "a").isSelectedByDefault)
        #expect(!UninstallLeftover(url: url, kind: .container, confidence: .high, ownerKey: "a").isSelectedByDefault)
        #expect(!UninstallLeftover(url: url, kind: .support, confidence: .high, ownerKey: "a").isSelectedByDefault)
        #expect(!UninstallLeftover(url: url, kind: .caches, confidence: .medium, ownerKey: "a").isSelectedByDefault)
    }

    @Test func findMeasuresAndRespectsExclusions() async throws {
        let t = try buildTree()
        let excluded = t.url("Library/Containers/com.acme.notes").path
        let filter = UninstallFilter(excluded: [excluded], checksSafety: false)
        let result = await UninstallLeftoverFinder.find(for: [notes], installed: [notes, notesPro, editor], home: t.root, filter: filter)
        let items = result[notes.url] ?? []
        #expect(!items.isEmpty)
        #expect(!items.contains { $0.url.path == excluded })
        let cache = items.first { $0.url.lastPathComponent == "com.acme.notes" && $0.kind == .caches }
        #expect((cache?.size ?? 0) >= 50_000)
    }

    @Test func blockedAppsGetNoLeftovers() async throws {
        let t = try buildTree()
        let apple = UninstallApp(url: URL(fileURLWithPath: "/Applications/Notes.app"), name: "Notes", bundleID: "com.acme.notes",
                                 isApple: true, blockReason: "Apple")
        let result = await UninstallLeftoverFinder.find(for: [apple], installed: [apple], home: t.root, filter: permissive)
        #expect(result[apple.url]?.isEmpty == true)
    }

    @Test func safetyGuardFiltersEverythingOutsideAllowedAreas() async throws {
        // Árvore no diretório temporário: fora da pasta pessoal, o guarda bloqueia tudo.
        let t = try buildTree()
        let guarded = UninstallFilter(excluded: [], checksSafety: true)
        let result = await UninstallLeftoverFinder.find(for: [notes], installed: [notes], home: t.root, filter: guarded)
        #expect(result[notes.url]?.isEmpty == true)
    }

    @Test func safetyGuardAllowsFakeHomeInsideRealHome() async throws {
        let t = try UninstallFakeTree(underHome: true)
        try t.file("Library/Preferences/com.acme.notes.plist")
        try t.file("Library/Caches/com.acme.notes/x")
        let guarded = UninstallFilter(excluded: [t.url("Library/Caches/com.acme.notes").path], checksSafety: true)
        let result = await UninstallLeftoverFinder.find(for: [notes], installed: [notes], home: t.root, filter: guarded)
        let names = (result[notes.url] ?? []).map(\.url.lastPathComponent)
        #expect(names == ["com.acme.notes.plist"])
    }
}

// MARK: - Restos de apps removidos

@Suite("Desinstalador: restos de apps removidos")
struct UninstallOrphanTests {
    let editor = app("com.acme.editor", name: "Editor", embedded: ["com.acme.editor.helper"])

    @Test func findsOnlyConservativeOrphans() async throws {
        let t = try UninstallFakeTree()
        try t.file("Library/Preferences/com.gone.app.plist")
        try t.file("Library/Caches/com.gone.app/data", bytes: 20_000)
        try t.dir("Library/Caches/com.gone.app.helper")
        try t.dir("Library/Group Containers/ABCDE12345.com.gone.app")
        try t.plist("Library/LaunchAgents/com.gone.app.agent.plist", ["Label": "com.gone.app.agent", "Program": "/nao/existe/gone"])
        // não podem aparecer:
        try t.file("Library/Preferences/com.acme.editor.helper.plist")     // instalado
        try t.file("Library/Preferences/com.acme.editor.plugin.plist")     // filho de instalado
        try t.file("Library/Preferences/com.acme.other.plist")             // mesmo fabricante de instalado
        try t.file("Library/Preferences/com.apple.finder.plist")           // Apple
        try t.dir("Library/Group Containers/group.com.apple.notes")         // Apple
        try t.file("Library/Preferences/org.sparkle-project.Sparkle.plist") // biblioteca compartilhada
        try t.file("Library/Preferences/com.running.app.plist")            // aberto agora
        try t.file("Library/Preferences/com.registered.app.plist")         // app existe em outro lugar
        try t.file("Library/Preferences/com.live.daemon.plist")            // agente vivo
        try t.dir("Library/Logs/1.2.3")                                    // não é identificador
        try t.dir("Library/Application Support/Spotify")                   // não é identificador
        try t.plist("Library/LaunchAgents/com.alive.agent.plist", ["Label": "com.alive.agent", "Program": "/bin/ls"])
        try t.ageLibrary(days: 60)
        // recentes (depois de envelhecer o resto):
        try t.dir("Library/Caches/com.recent.app")
        try t.file("Library/Caches/com.deep.app/old")
        try t.age("Library/Caches/com.deep.app", days: 90)
        try t.file("Library/Caches/com.deep.app/new")   // algo lá dentro mudou hoje

        let groups = await UninstallOrphanFinder.find(
            installed: [editor], runningIDs: ["com.running.app"], home: t.root, filter: permissive,
            isRegistered: { $0.lowercased() == "com.registered.app" }, liveAgentLabels: ["com.live.daemon"]
        )
        #expect(groups.map(\.key) == ["com.gone.app"])
        let names = Set(groups.first?.items.map(\.url.lastPathComponent) ?? [])
        #expect(names == ["com.gone.app.plist", "com.gone.app", "com.gone.app.helper", "ABCDE12345.com.gone.app",
                          "com.gone.app.agent.plist"])
        #expect(groups.first?.items.allSatisfy { $0.confidence == .medium } == true)
        #expect((groups.first?.size ?? 0) >= 20_000)
    }

    @Test func installedPrefixAndVendorExclude() {
        let context = UninstallOrphanContext(installedIDs: ["com.acme.editor"], runningIDs: ["net.busy.tool"])
        func candidate(_ name: String, _ location: UninstallLocation = .preferences) -> String? {
            UninstallOrphanFinder.candidateKey(for: UninstallLibraryEntry(url: URL(fileURLWithPath: "/x/\(name)"), location: location),
                                               context: context)
        }
        #expect(candidate("com.acme.editor.plist") == nil)
        #expect(candidate("com.acme.editor.helper.plist") == nil)
        #expect(candidate("com.acme.plist") == nil)
        #expect(candidate("com.acme.viewer.plist") == nil)
        #expect(candidate("net.busy.tool.plist") == nil)
        #expect(candidate("net.busy.other.plist") == nil)
        #expect(candidate("com.apple.Safari.plist") == nil)
        #expect(candidate("group.com.apple.notes", .groupContainers) == nil)
        #expect(candidate("com.lipenoe.cleanercrtv.plist") == nil)
        #expect(candidate("org.gone.app.plist") == "org.gone.app")
    }

    @Test func launchAgentsNeedMissingProgram() {
        let context = UninstallOrphanContext(installedIDs: [])
        func entry(_ program: String?, exists: Bool) -> UninstallLibraryEntry {
            UninstallLibraryEntry(url: URL(fileURLWithPath: "/x/com.gone.agent.plist"), location: .launchAgents,
                                  agent: .init(label: "com.gone.agent", program: program, programExists: exists))
        }
        #expect(UninstallOrphanFinder.candidateKey(for: entry("/nao/existe", exists: false), context: context) == "com.gone.agent")
        #expect(UninstallOrphanFinder.candidateKey(for: entry("/bin/ls", exists: true), context: context) == nil)
        #expect(UninstallOrphanFinder.candidateKey(for: entry(nil, exists: false), context: context) == nil)
    }

    @Test func groupsHelpersUnderParent() {
        let url = URL(fileURLWithPath: "/x")
        let items = [
            UninstallLeftover(url: url.appendingPathComponent("a"), kind: .caches, confidence: .medium, ownerKey: "com.a.app", size: 5),
            UninstallLeftover(url: url.appendingPathComponent("b"), kind: .caches, confidence: .medium, ownerKey: "com.a.app.helper", size: 5),
            UninstallLeftover(url: url.appendingPathComponent("c"), kind: .logs, confidence: .medium, ownerKey: "com.b.app", size: 1),
            UninstallLeftover(url: url.appendingPathComponent("d"), kind: .logs, confidence: .medium, ownerKey: "com.a.application", size: 1),
        ]
        let groups = UninstallOrphanFinder.group(items)
        #expect(groups.map(\.key) == ["com.a.app", "com.a.application", "com.b.app"])
        #expect(groups.first?.items.count == 2)
    }
}

// MARK: - Inventário

@Suite("Desinstalador: inventário")
struct UninstallInventoryTests {
    @Test func readsBundlesOneLevelDeep() async throws {
        let t = try UninstallFakeTree()
        try t.plist("Applications/Foo.app/Contents/Info.plist", [
            "CFBundleIdentifier": "com.acme.foo", "CFBundleShortVersionString": "2.1",
            "CFBundleName": "Foo", "CFBundleDisplayName": "Foo Pro",
        ])
        try t.file("Applications/Foo.app/Contents/_MASReceipt/receipt")
        try t.file("Applications/Foo.app/Contents/MacOS/Foo", bytes: 100_000)
        try t.plist("Applications/Foo.app/Contents/PlugIns/Share.appex/Contents/Info.plist", ["CFBundleIdentifier": "com.acme.foo.share"])
        try t.plist("Applications/Foo.app/Contents/Helpers/Inner.app/Contents/Info.plist", ["CFBundleIdentifier": "com.acme.foo.inner"])
        try t.plist("Applications/Suite/Bar.app/Contents/Info.plist", ["CFBundleIdentifier": "com.acme.bar"])
        try t.plist("Applications/Suite/Deeper/Baz.app/Contents/Info.plist", ["CFBundleIdentifier": "com.acme.baz"])
        try t.plist("Applications/AppleThing.app/Contents/Info.plist", ["CFBundleIdentifier": "com.apple.thing"])
        try t.plist("Applications/Me.app/Contents/Info.plist", ["CFBundleIdentifier": "com.lipenoe.cleanercrtv"])
        try t.plist("Applications/Excluded.app/Contents/Info.plist", ["CFBundleIdentifier": "com.acme.excluded"])
        try t.file("Applications/NotAnApp/readme.txt")
        try FileManager.default.createSymbolicLink(at: t.url("Applications/Link.app"), withDestinationURL: t.url("Applications/Foo.app"))

        let filter = UninstallFilter(excluded: [t.url("Applications/Excluded.app").path], checksSafety: false)
        let apps = await UninstallInventory.discover(roots: [t.url("Applications")], filter: filter)
        #expect(Set(apps.map(\.name)) == ["Foo", "Bar", "AppleThing", "Me"])

        let foo = try #require(apps.first { $0.name == "Foo" })
        #expect(foo.bundleID == "com.acme.foo")
        #expect(foo.version == "2.1")
        #expect(foo.isAppStore)
        #expect(!foo.isApple && !foo.isSelf && foo.canUninstall)
        #expect(foo.aliases.contains("Foo Pro"))
        #expect(Set(foo.embeddedBundleIDs) == ["com.acme.foo.share", "com.acme.foo.inner"])
        #expect(foo.matchIDs == ["com.acme.foo", "com.acme.foo.inner", "com.acme.foo.share"])
        #expect(foo.size == nil)

        let appleApp = try #require(apps.first { $0.name == "AppleThing" })
        #expect(appleApp.isApple && !appleApp.canUninstall)
        let me = try #require(apps.first { $0.name == "Me" })
        #expect(me.isSelf && !me.canUninstall)

        let sizes = UninstallSizes()
        await UninstallInventory.measureSizes(of: [foo.url]) { url, size in sizes.set(url, size) }
        #expect((sizes.get(foo.url) ?? 0) >= 100_000)
    }

    @Test func unusedNeedsKnownDate() {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let old = UninstallApp(url: URL(fileURLWithPath: "/a.app"), name: "A", bundleID: "x.y.a", lastUsed: cutoff.addingTimeInterval(-10))
        let unknown = UninstallApp(url: URL(fileURLWithPath: "/b.app"), name: "B", bundleID: "x.y.b")
        #expect(old.isUnused(since: cutoff))
        #expect(!unknown.isUnused(since: cutoff))
    }

    @Test func measureReportsSizeAndNewestDate() throws {
        let t = try UninstallFakeTree()
        try t.file("pasta/a", bytes: 40_000)
        try t.file("pasta/sub/b", bytes: 40_000)
        try t.age("pasta", days: 100)
        let old = UninstallMeasure.measure(t.url("pasta"))
        #expect(old.bytes >= 80_000)
        #expect((old.newest ?? .now) < Date().addingTimeInterval(-99 * 86_400))
        try t.file("pasta/sub/c")
        let fresh = UninstallMeasure.measure(t.url("pasta"))
        #expect((fresh.newest ?? .distantPast) > Date().addingTimeInterval(-60))
    }
}

private final class UninstallSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: Int64] = [:]
    func set(_ url: URL, _ size: Int64) { lock.withLock { values[url] = size } }
    func get(_ url: URL) -> Int64? { lock.withLock { values[url] } }
}
