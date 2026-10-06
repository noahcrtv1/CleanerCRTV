import Foundation
import Testing
@testable import CleanerCore

/// Pasta pessoal de mentira numa pasta temporária. Nada fora dela é lido ou alterado.
final class CleanupFakeHome {
    let root: URL
    /// "Agora" da varredura: 30 dias no futuro, para que tudo criado pelo teste pareça antigo
    /// (a data de chegada na pasta não pode ser mudada; a de modificação, sim).
    let now = Date().addingTimeInterval(30 * 86_400)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    /// Cria um arquivo com conteúdo. `age` = quanto tempo antes de `now` foi modificado.
    @discardableResult
    func file(_ path: String, bytes: Int = 6_000, age: TimeInterval? = nil) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        if let age {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        return url
    }

    func plist(_ path: String, _ object: [String: Any]) throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try data.write(to: url)
    }

    /// Mesmas regras do `SafetyGuard`, com esta pasta fazendo o papel da pasta pessoal.
    var guardCheck: @Sendable (URL) -> Bool {
        let home = SafetyGuard.realpathString(root.path) ?? root.path
        return { url in
            guard let canonical = SafetyGuard.canonicalPath(url) else { return false }
            return SafetyGuard.check(canonical: canonical, home: home).isAllowed
        }
    }

    func options(running: Set<String> = [], names: Set<String> = [], fda: Bool = true, excluded: [String] = [],
                 allowed: (@Sendable (URL) -> Bool)? = nil,
                 categories: Set<CleanupCategoryID> = Set(CleanupCategoryID.allCases)) -> CleanupScanner.Options {
        CleanupScanner.Options(home: root, runningBundleIDs: running, runningAppNames: names, hasFullDiskAccess: fda,
                               now: now, categories: categories, excludedPaths: excluded,
                               isAllowed: allowed ?? guardCheck, resolver: CleanupAppResolver(lookup: { _ in nil }),
                               maxConcurrentSizing: 4)
    }

    func scan(_ options: CleanupScanner.Options) async -> CleanupScanResult {
        await CleanupScanner().scan(options)
    }
}

extension CleanupScanResult {
    /// Item pelo caminho relativo à pasta pessoal de mentira.
    func entry(_ relative: String, in home: CleanupFakeHome) -> CleanupEntry? {
        let suffix = home.root.lastPathComponent + "/" + relative
        return entries.first { $0.url.standardizedFileURL.path.hasSuffix(suffix) }
    }

    func has(_ relative: String, in home: CleanupFakeHome) -> Bool { entry(relative, in: home) != nil }
}

private let day: TimeInterval = 86_400

@Suite("Lixo do sistema: regras")
struct CleanupRuleTests {
    @Test func findsJunkInEachCategory() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/com.foo.app/Cache.db")
        try home.file("Library/Developer/Xcode/DerivedData/MeuApp-abcdefghijklmnopqrstuvwxyz/Build/x.o")
        try home.file("Library/Caches/org.swift.swiftpm/repositories/pkg")
        try home.file(".npm/_cacache/index-v5/aa")
        try home.file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/ABC-123/contrato.pdf")
        try home.file("Library/Saved Application State/com.foo.app.savedState/windows.plist")
        try home.file(".Trash/velho.zip")

        let result = await home.scan(home.options())

        let cache = try #require(result.entry("Library/Caches/com.foo.app", in: home))
        #expect(cache.category == .appCaches)
        #expect(cache.isRecommended)
        #expect(cache.bundleID == "com.foo.app")
        #expect(cache.size > 0)

        let derived = try #require(result.entry("Library/Developer/Xcode/DerivedData/MeuApp-abcdefghijklmnopqrstuvwxyz", in: home))
        #expect(derived.category == .developer)
        #expect(derived.label == "MeuApp")
        #expect(derived.isRecommended)

        #expect(result.entry("Library/Caches/org.swift.swiftpm", in: home)?.category == .developer)
        #expect(result.entry(".npm/_cacache", in: home)?.category == .developer)

        let mail = try #require(result.entry("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/ABC-123", in: home))
        #expect(mail.category == .mailAttachments)
        #expect(mail.isRecommended)

        let saved = try #require(result.entry("Library/Saved Application State/com.foo.app.savedState", in: home))
        #expect(saved.category == .savedState)
        #expect(!saved.isRecommended, "estado salvo é opcional")

        let trash = try #require(result.entry(".Trash/velho.zip", in: home))
        #expect(trash.category == .trash)
        #expect(!trash.isRecommended, "a Lixeira tem ação própria e nunca entra no Limpar")
    }

    @Test func protectedCachesAreNeverListed() async throws {
        let home = try CleanupFakeHome()
        for name in ["CloudKit", "com.apple.bird", "com.apple.cloudd", "com.apple.akd", "com.apple.nsurlsessiond",
                     "com.apple.containermanagerd", "com.apple.homed", "FamilyCircle", "com.apple.ap.adprivacyd",
                     "com.apple.iCloudHelper", "com.lipenoe.cleanercrtv", "com.apple.amsaccountsd"] {
            try home.file("Library/Caches/\(name)/dados")
        }
        try home.file("Library/Caches/com.livre.app/dados")

        let result = await home.scan(home.options())
        #expect(result.has("Library/Caches/com.livre.app", in: home))
        #expect(result.entries.count == 1, "só o cache comum: \(result.entries.map(\.url.lastPathComponent))")
    }

    @Test func browsersOnlyTouchCacheFolders() async throws {
        let home = try CleanupFakeHome()
        let profile = "Library/Application Support/Google/Chrome/Default"
        for sub in ["Cache/Cache_Data/f_0001", "Code Cache/js/x", "GPUCache/data_0",
                    "Service Worker/CacheStorage/abc", "Service Worker/ScriptCache/def"] {
            try home.file("\(profile)/\(sub)")
        }
        for keep in ["Cookies", "History", "Login Data", "Bookmarks", "Local Storage/leveldb/1.ldb",
                     "IndexedDB/https_site/1", "Extensions/abc/1.0/manifest.json", "Service Worker/Database/1"] {
            try home.file("\(profile)/\(keep)")
        }
        try home.file("Library/Application Support/Google/Chrome/GrShaderCache/data_1")
        try home.file("Library/Application Support/com.operasoftware.Opera/Code Cache/js/1")
        try home.file("Library/Application Support/com.operasoftware.Opera/Cookies")
        try home.file("Library/Caches/Firefox/Profiles/ab12.default-release/cache2/entries/1")
        try home.file("Library/Application Support/Firefox/Profiles/ab12.default-release/places.sqlite")

        let result = await home.scan(home.options())
        let browserPaths = result.entries.filter { $0.category == .browsers }

        for sub in ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache"] {
            #expect(result.entry("\(profile)/\(sub)", in: home)?.category == .browsers, "\(sub)")
        }
        #expect(result.has("Library/Application Support/Google/Chrome/GrShaderCache", in: home))
        #expect(result.has("Library/Application Support/com.operasoftware.Opera/Code Cache", in: home))
        #expect(result.has("Library/Caches/Firefox/Profiles/ab12.default-release/cache2", in: home))
        #expect(browserPaths.count == 8)
        for entry in result.entries {
            let path = entry.url.path
            for forbidden in ["Cookies", "History", "Login Data", "Bookmarks", "Local Storage", "IndexedDB",
                              "Extensions", "Service Worker/Database", "places.sqlite"] {
                #expect(!path.contains(forbidden), "nunca: \(path)")
            }
        }
        let firefox = try #require(result.entry("Library/Caches/Firefox/Profiles/ab12.default-release/cache2", in: home))
        #expect(firefox.label == "Firefox")
        #expect(firefox.detail == "cache2 · default-release")
    }

    @Test func containerCachesListChildrenOfTheCachesFolder() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Containers/com.spotify.client/Data/Library/Caches/com.spotify.client/fsCachedData/1")
        try home.file("Library/Containers/com.spotify.client/Data/Library/Caches/WebKit/2")
        try home.file("Library/Containers/com.spotify.client/Data/Documents/importante.txt")
        try home.file("Library/Containers/com.apple.siri.media-indexer/Data/Library/Caches/x/1")
        try home.file("Library/Containers/com.getdropbox.dropbox.fileprovider/Data/Library/Caches/pendente/1")

        let result = await home.scan(home.options())
        let base = "Library/Containers/com.spotify.client/Data/Library/Caches"
        #expect(result.entry("\(base)/com.spotify.client", in: home)?.category == .containerCaches)
        #expect(result.entry("\(base)/com.spotify.client", in: home)?.bundleID == "com.spotify.client")
        #expect(result.has("\(base)/WebKit", in: home))
        #expect(!result.has(base, in: home), "nunca a pasta Caches inteira")
        #expect(!result.has("Library/Containers/com.spotify.client", in: home), "nunca o contêiner")
        #expect(!result.entries.contains { $0.url.path.contains("Documents") })
        #expect(!result.entries.contains { $0.url.path.contains("com.apple.siri") }, "serviços da Apple ficam de fora")
        #expect(!result.entries.contains { $0.url.path.contains("fileprovider") }, "sincronização fica de fora")
    }

    @Test func developerOptionalItemsStartUnselected() async throws {
        let home = try CleanupFakeHome()
        let support = "Library/Developer/Xcode/iOS DeviceSupport"
        try home.file("\(support)/17.5.1 (21F90)/Symbols/x")
        try home.file("\(support)/iPhone15,2 17.5.1 (21F90)/Symbols/x")
        try home.file("\(support)/iPhone16,1 18.0 (22A3354)/Symbols/x")
        try home.file("Library/Developer/Xcode/Archives/2026-01-10/MeuApp 10-01-26.xcarchive/Info.plist")
        try home.file(".gradle/caches/modules-2/x")
        try home.file("Library/Caches/Homebrew/downloads/x.tar.gz")

        let result = await home.scan(home.options())
        let old = try #require(result.entry("\(support)/17.5.1 (21F90)", in: home))
        #expect(!old.isRecommended)
        #expect(old.label == "iOS 17.5.1")
        #expect(result.has("\(support)/iPhone15,2 17.5.1 (21F90)", in: home))
        #expect(!result.has("\(support)/iPhone16,1 18.0 (22A3354)", in: home), "a versão mais nova fica")

        let archive = try #require(result.entry("Library/Developer/Xcode/Archives/2026-01-10/MeuApp 10-01-26.xcarchive", in: home))
        #expect(!archive.isRecommended)
        #expect(archive.note != nil)
        #expect(result.entry(".gradle/caches", in: home)?.isRecommended == false)
        #expect(result.entry("Library/Caches/Homebrew", in: home)?.isRecommended == true)
    }

    @Test func iosBackupsAreLabeledFromInfoPlist() async throws {
        let home = try CleanupFakeHome()
        let backup = "Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E"
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        try home.plist("\(backup)/Info.plist", ["Device Name": "iPhone da Ana", "Last Backup Date": date,
                                                "Product Version": "26.0"])
        try home.file("\(backup)/Manifest.db", bytes: 50_000)

        let result = await home.scan(home.options())
        let entry = try #require(result.entry(backup, in: home))
        #expect(entry.category == .iosBackups)
        #expect(entry.label == "iPhone da Ana")
        #expect(entry.detail?.hasPrefix("iOS 26.0") == true)
        #expect(entry.lastModified == date)
        #expect(!entry.isRecommended)
    }

    @Test func emptyItemsAreIgnored() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/com.vazio.app/nada", bytes: 0)
        try FileManager.default.createDirectory(at: home.url("Library/Caches/com.pasta.vazia"), withIntermediateDirectories: true)
        try home.file("Library/Caches/.DS_Store")

        let result = await home.scan(home.options())
        #expect(result.entries.isEmpty, "\(result.entries.map(\.url.lastPathComponent))")
    }
}

@Suite("Lixo do sistema: sobreposição")
struct CleanupOverlapTests {
    @Test func specificCategoriesClaimFirstAndNothingRepeats() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/Google/Chrome/Default/Cache/1")
        try home.file("Library/Caches/Google/Updater/2")
        try home.file("Library/Caches/Firefox/Profiles/ab12.default-release/cache2/1")
        try home.file("Library/Caches/Firefox/Profiles/ab12.default-release/safebrowsing/2")
        try home.file("Library/Caches/com.apple.Safari/WebKitCache/1")
        try home.file("Library/Caches/org.swift.swiftpm/3")
        try home.file("Library/Caches/JetBrains/IntelliJIdea2026.1/caches/4")
        try home.file("Library/Caches/com.apple.dt.Xcode/5")
        try home.file("Library/Caches/com.outro.app/6")

        let result = await home.scan(home.options())

        #expect(result.entry("Library/Caches/Google/Chrome", in: home)?.category == .browsers)
        #expect(result.entry("Library/Caches/Google/Updater", in: home)?.category == .appCaches)
        #expect(!result.has("Library/Caches/Google", in: home), "a pasta-mãe é dividida, não listada")
        #expect(result.entry("Library/Caches/Firefox/Profiles/ab12.default-release/cache2", in: home)?.category == .browsers)
        #expect(result.entry("Library/Caches/Firefox/Profiles/ab12.default-release/safebrowsing", in: home)?.category == .appCaches)
        #expect(result.entry("Library/Caches/com.apple.Safari", in: home)?.category == .browsers)
        #expect(result.entry("Library/Caches/org.swift.swiftpm", in: home)?.category == .developer)
        #expect(result.entry("Library/Caches/JetBrains/IntelliJIdea2026.1", in: home)?.category == .developer)
        #expect(result.entry("Library/Caches/com.apple.dt.Xcode", in: home)?.category == .developer)
        #expect(result.entry("Library/Caches/com.outro.app", in: home)?.category == .appCaches)

        let paths = result.entries.map { $0.url.standardizedFileURL.path }
        #expect(Set(paths).count == paths.count, "nenhum item duas vezes")
        for a in paths {
            for b in paths where a != b {
                #expect(!b.hasPrefix(a + "/"), "pai e filho listados juntos: \(a) ⊃ \(b)")
            }
        }
    }

    @Test func claimSkipsInsideAndSplitsAround() throws {
        let home = try CleanupFakeHome()
        let options = home.options()
        let discovery = CleanupDiscovery(options: options, excluded: [], cancel: CleanupCancelFlag()) { _ in }
        try home.file("Library/Caches/Pai/Filho/1")
        try home.file("Library/Caches/Pai/Irmao/2")

        let category = CleanupCatalog.category(.appCaches)
        let rule = category.rules[0]
        func candidate(_ relative: String) -> CleanupCandidate {
            let url = home.url(relative)
            return CleanupCandidate(url: url, path: url.standardizedFileURL.path, categoryID: .appCaches,
                                    categoryRecommended: true, rule: rule, base: home.url("Library/Caches").path,
                                    captures: [], isDirectory: true, modified: nil)
        }
        #expect(discovery.claim(candidate("Library/Caches/Pai/Filho"), depth: 0).count == 1)
        #expect(discovery.claim(candidate("Library/Caches/Pai/Filho"), depth: 0).isEmpty, "mesmo caminho de novo")
        #expect(discovery.claim(candidate("Library/Caches/Pai/Filho/neto"), depth: 0).isEmpty, "dentro de um já reivindicado")
        let split = discovery.claim(candidate("Library/Caches/Pai"), depth: 0)
        #expect(split.map(\.url.lastPathComponent) == ["Irmao"], "o pai vira só os filhos livres")
    }

    @Test func exclusionsAndProtectedPathsSplitTheirParents() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/com.ignorado.app/1")
        try home.file("Library/Caches/Grande/manter/1")
        try home.file("Library/Caches/Grande/limpar/2")
        try home.file("Library/Caches/Google/DriveFS/pendente/3")
        try home.file("Library/Caches/Google/Outro/4")

        let excluded = [home.url("Library/Caches/com.ignorado.app").path, home.url("Library/Caches/Grande/manter").path]
        let result = await home.scan(home.options(excluded: excluded))

        #expect(!result.has("Library/Caches/com.ignorado.app", in: home))
        #expect(!result.has("Library/Caches/Grande", in: home))
        #expect(!result.has("Library/Caches/Grande/manter", in: home))
        #expect(result.has("Library/Caches/Grande/limpar", in: home))
        #expect(!result.entries.contains { $0.url.path.contains("DriveFS") }, "Google Drive nunca entra")
        #expect(!result.has("Library/Caches/Google", in: home))
        #expect(result.has("Library/Caches/Google/Outro", in: home))
    }

    @Test func ideLocalHistoryIsNeverListed() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/JetBrains/IntelliJIdea2026.1/caches/1")
        try home.file("Library/Caches/JetBrains/IntelliJIdea2026.1/LocalHistory/changes.storageData")
        try home.file("Library/Caches/Google/AndroidStudio2026.1/caches/2")
        try home.file("Library/Caches/Google/AndroidStudio2026.1/LocalHistory/changes.storageData")

        let result = await home.scan(home.options())
        #expect(!result.entries.contains { $0.url.path.contains("LocalHistory") }, "histórico local não é cache")
        #expect(!result.has("Library/Caches/JetBrains/IntelliJIdea2026.1", in: home), "a pasta do IDE é dividida")
        let jetbrains = try #require(result.entry("Library/Caches/JetBrains/IntelliJIdea2026.1/caches", in: home))
        #expect(jetbrains.category == .developer)
        #expect(jetbrains.detail == "IntelliJIdea2026.1/caches")
        #expect(result.entry("Library/Caches/Google/AndroidStudio2026.1/caches", in: home)?.category == .appCaches)
        #expect(!result.has("Library/Caches/Google/AndroidStudio2026.1", in: home))
    }

    @Test func claimsIgnoreLetterCase() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/com.apple.safari/WebKitCache/1")
        // Só faz sentido num volume que ignora maiúsculas (o padrão do APFS no Mac).
        guard FileManager.default.fileExists(atPath: home.url("Library/Caches/com.apple.Safari").path) else { return }

        let result = await home.scan(home.options())
        let safari = result.entries.filter { $0.url.path.lowercased().hasSuffix("library/caches/com.apple.safari") }
        #expect(safari.count == 1, "o mesmo item uma vez só: \(safari.map(\.url.path))")
        #expect(safari.first?.category == .browsers)
    }

    @Test func protectedPatternsExpandToRealFolders() throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/JetBrains/A/LocalHistory/1")
        try home.file("Library/Caches/JetBrains/B/caches/1")
        let paths = CleanupDiscovery.expandProtected(["Library/Caches/JetBrains/*/LocalHistory", "Fixo/Caminho"],
                                                     home: home.root)
        let root = home.root.standardizedFileURL.path
        #expect(paths == [root + "/Library/Caches/JetBrains/A/LocalHistory"], "só o que existe")
    }

    @Test func itemsTheGuardWouldBlockAreNeverProposed() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/com.bloqueado.app/1")
        try home.file("Library/Caches/com.livre.app/2")
        try home.file("Library/Logs/app.log")
        let guardCheck = home.guardCheck
        let allowed: @Sendable (URL) -> Bool = { url in
            !url.path.contains("com.bloqueado.app") && guardCheck(url)
        }
        let result = await home.scan(home.options(allowed: allowed))
        #expect(!result.has("Library/Caches/com.bloqueado.app", in: home))
        #expect(result.has("Library/Caches/com.livre.app", in: home))
        for entry in result.entries {
            #expect(guardCheck(entry.url), "o guarda bloquearia \(entry.url.path)")
        }
    }
}

@Suite("Lixo do sistema: apps abertos")
struct CleanupRunningAppTests {
    @Test func runningAppItemsStartUnselected() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/com.foo.app/1")
        try home.file("Library/Caches/com.foo.app.helper/2")
        try home.file("Library/Caches/com.bar.app/3")
        try home.file("Library/Containers/com.foo.app/Data/Library/Caches/com.foo.app/4")
        try home.file("Library/Caches/Firefox/Profiles/ab12.default-release/cache2/5")
        try home.file("Library/Caches/Firefox/Profiles/ab12.default-release/outro/6")
        try home.file("Library/Caches/Google/Chrome/Default/Cache/7")

        let result = await home.scan(home.options(running: ["com.foo.app", "com.google.Chrome"], names: ["Firefox"]))

        for path in ["Library/Caches/com.foo.app", "Library/Caches/com.foo.app.helper",
                     "Library/Containers/com.foo.app/Data/Library/Caches/com.foo.app",
                     "Library/Caches/Google/Chrome",
                     "Library/Caches/Firefox/Profiles/ab12.default-release/outro"] {
            let entry = try #require(result.entry(path, in: home), "\(path)")
            #expect(entry.isAppRunning, "\(path)")
            #expect(!entry.isRecommended, "\(path)")
        }
        let bar = try #require(result.entry("Library/Caches/com.bar.app", in: home))
        #expect(!bar.isAppRunning)
        #expect(bar.isRecommended)
    }

    @Test(arguments: [
        (["com.foo.app"], ["com.foo.app"], true),
        (["com.foo.app.helper"], ["com.foo.app"], true),
        (["com.foo.app.share-extension.x"], ["com.foo.app"], true),
        (["com.apple.dt.instruments"], ["com.apple.dt.xcode"], false),
        (["com.foo"], ["com.foo.app"], false),
        (["com.jetbrains.*"], ["com.jetbrains.intellij"], true),
        (["com.jetbrains.*"], ["com.google.chrome"], false),
        (["COM.Foo.App"], ["com.foo.app"], true),
        ([String](), ["com.foo.app"], false),
    ])
    func runningMatch(owners: [String], running: [String], expected: Bool) {
        #expect(CleanupScanner.isRunning(owners: owners, running: Set(running)) == expected)
    }
}

@Suite("Lixo do sistema: idade e atividade")
struct CleanupAgeTests {
    @Test func installersOlderThanTwoWeeks() async throws {
        let home = try CleanupFakeHome()
        try home.file("Downloads/Velho.dmg")                       // 30 dias
        try home.file("Downloads/Novo.pkg", age: 2 * day)
        try home.file("Downloads/Sistema.iso", age: 15 * day)
        try home.file("Downloads/Planilha.xlsx")                   // não é instalador
        try home.file("Downloads/Projeto.zip")

        let result = await home.scan(home.options())
        let installers = result.entries.filter { $0.category == .installers }.map(\.url.lastPathComponent).sorted()
        #expect(installers == ["Sistema.iso", "Velho.dmg"])
        #expect(installers.allSatisfy { name in result.entries.first { $0.url.lastPathComponent == name }?.isRecommended == false },
                "instaladores nunca entram marcados")
    }

    @Test func diagnosticReportsKeepTheLastWeek() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Logs/DiagnosticReports/Velho-2026-01-01.ips", age: 10 * day)
        try home.file("Library/Logs/DiagnosticReports/Recente-2026-02-01.ips", age: 2 * day)
        try home.file("Library/Logs/DiagnosticReports/Retired/Aposentado.ips", age: 20 * day)

        let result = await home.scan(home.options())
        let logs = result.entries.filter { $0.category == .logs }.map(\.url.lastPathComponent).sorted()
        #expect(logs == ["Aposentado.ips", "Velho-2026-01-01.ips"])
        #expect(!result.has("Library/Logs/DiagnosticReports", in: home), "a pasta em si nunca sai")
    }

    @Test func logsBeingWrittenAreSkippedOrUnselected() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Logs/antigo.log", age: 3 * day)
        try home.file("Library/Logs/gravando.log", age: 60)
        try home.file("Library/Logs/com.ativo.app/hoje.log", age: 120)
        try home.file("Library/Logs/com.parado.app/ontem.log", age: day)

        let result = await home.scan(home.options())
        #expect(result.entry("Library/Logs/antigo.log", in: home)?.isRecommended == true)
        #expect(!result.has("Library/Logs/gravando.log", in: home), "arquivo sendo gravado fica de fora")
        let active = try #require(result.entry("Library/Logs/com.ativo.app", in: home))
        #expect(active.isActive)
        #expect(!active.isRecommended)
        let idle = try #require(result.entry("Library/Logs/com.parado.app", in: home))
        #expect(!idle.isActive)
        #expect(idle.isRecommended)
    }

    @Test func ageFilterUsesNewestOfModifiedAndAdded() {
        let now = Date()
        let url = URL(fileURLWithPath: "/tmp/x.dmg")
        let filter = CleanupFilter(extensions: ["dmg"], minAge: 14 * day)
        let old = CleanupListedItem(url: url, name: "x.dmg", isDirectory: false,
                                    modified: now.addingTimeInterval(-40 * day), added: now.addingTimeInterval(-20 * day))
        let justDownloaded = CleanupListedItem(url: url, name: "x.dmg", isDirectory: false,
                                               modified: now.addingTimeInterval(-40 * day), added: now.addingTimeInterval(-day))
        let noDate = CleanupListedItem(url: url, name: "x.dmg", isDirectory: false, modified: nil)
        #expect(CleanupDiscovery.accepts(old, filter: filter, now: now))
        #expect(!CleanupDiscovery.accepts(justDownloaded, filter: filter, now: now))
        #expect(!CleanupDiscovery.accepts(noDate, filter: filter, now: now))
    }
}

@Suite("Lixo do sistema: acesso e cancelamento")
struct CleanupAccessTests {
    @Test func withoutFullDiskAccessContainersAreSkippedAndCounted() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Containers/com.spotify.client/Data/Library/Caches/x/1")
        try home.file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A/1.pdf")
        try home.file("Library/Caches/com.foo.app/1")

        let result = await home.scan(home.options(fda: false))
        #expect(!result.entries.contains { $0.url.path.contains("/Containers/") })
        #expect(result.has("Library/Caches/com.foo.app", in: home))
        #expect(result.inaccessibleCount > 0)
    }

    @Test func unreadableFoldersAreCounted() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/com.trancado.app/1")
        try home.file("Library/Caches/com.livre.app/2")
        let locked = home.url("Library/Caches/com.trancado.app")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            // Devolve a permissão antes de apagar a pasta de teste (sem ela, a remoção falharia).
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: home.root)
        }

        let result = await home.scan(home.options())
        #expect(!result.has("Library/Caches/com.trancado.app", in: home))
        #expect(result.has("Library/Caches/com.livre.app", in: home))
        #expect(result.inaccessiblePaths.contains { $0.hasSuffix("com.trancado.app") })
    }

    @Test func cancelledScanStopsEarly() async throws {
        let home = try CleanupFakeHome()
        try home.file("Library/Caches/com.foo.app/1")
        let options = home.options()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CleanupScanner().scan(options)
        }.value
        #expect(result.wasCancelled)
        #expect(result.entries.isEmpty)
    }

    @Test func progressIsReported() async throws {
        let home = try CleanupFakeHome()
        for i in 0..<20 { try home.file("Library/Caches/com.app\(i).x/1") }
        let box = CleanupTestBox()
        let result = await CleanupScanner().scan(home.options()) { box.append($0) }
        #expect(result.entries.count == 20)
        let last = try #require(box.values.last)
        #expect(last.stage == .measuring)
        #expect(last.measured == last.total)
        #expect(last.foundCount == 20)
    }
}

final class CleanupTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CleanupScanProgress] = []
    var values: [CleanupScanProgress] { lock.withLock { storage } }
    func append(_ value: CleanupScanProgress) { lock.withLock { storage.append(value) } }
}

@Suite("Lixo do sistema: catálogo e rótulos")
struct CleanupCatalogTests {
    @Test func catalogCoversEveryCategoryOnce() {
        let ids = CleanupCatalog.all.map(\.id)
        #expect(ids.count == CleanupCategoryID.allCases.count)
        #expect(Set(ids) == Set(CleanupCategoryID.allCases))
        for category in CleanupCatalog.all {
            #expect(!category.rules.isEmpty, "\(category.id)")
            #expect(!category.title.isEmpty && !category.explanation.isEmpty)
        }
        #expect(CleanupCatalog.category(.trash).isTrash)
        #expect(!CleanupCatalog.category(.installers).isRecommended)
        #expect(!CleanupCatalog.category(.iosBackups).isRecommended)
        #expect(CleanupCatalog.category(.appCaches).claimOrder > CleanupCatalog.category(.browsers).claimOrder)
    }

    @Test func rulesNeverPointAtStandardFoldersThemselves() {
        // Regras `.itself` nunca apontam para uma pasta que o SafetyGuard protege inteira.
        let home = "/Users/teste"
        let protected = SafetyGuard.protectedExact(home: home)
        for category in CleanupCatalog.all {
            for rule in category.rules where rule.mode == .itself && !rule.pattern.contains("*") {
                #expect(!protected.contains(home + "/" + rule.pattern), "\(rule.pattern)")
            }
        }
    }

    @Test func labelHelpers() {
        #expect(CleanupLabels.derivedDataProject("MeuApp-abcdefghijklmnopqrstuvwxyz") == "MeuApp")
        #expect(CleanupLabels.derivedDataProject("Meu-App-abcdefghijklmnopqrstuvwxyz") == "Meu-App")
        #expect(CleanupLabels.derivedDataProject("ModuleCache.noindex") == "ModuleCache.noindex")
        #expect(CleanupLabels.version(in: "iPhone16,1 17.5.1 (21F90)") == [17, 5, 1])
        #expect(CleanupLabels.version(in: "18.0 (22A3354)") == [18, 0])
        #expect(CleanupLabels.version(in: "sem versão") == nil)
        #expect(CleanupLabels.compare([17, 5], [17, 5, 0]) == 0)
        #expect(CleanupLabels.compare([17, 5, 1], [18]) < 0)
        #expect(CleanupLabels.profileName("ab12cd.default-release") == "default-release")
        #expect(CleanupLabels.profileName("Profile 1") == "Profile 1")
        #expect(CleanupLabels.stripSavedState("com.foo.app.savedState") == "com.foo.app")
        #expect(CleanupAppResolver.looksLikeBundleID("com.foo.app"))
        #expect(!CleanupAppResolver.looksLikeBundleID("Google"))
        #expect(!CleanupAppResolver.looksLikeBundleID("Meu App.v2"))
    }

    @Test func resolverFallsBackToTheMainApp() {
        let resolver = CleanupAppResolver(lookup: { id in
            id == "com.empresa.app" ? URL(fileURLWithPath: "/Applications/Empresa.app") : nil
        })
        #expect(resolver.app(for: "com.empresa.app")?.name == "Empresa")
        #expect(resolver.app(for: "com.empresa.app.ShipIt")?.name == "Empresa")
        #expect(resolver.app(for: "com.empresa.app.helper.renderer")?.url.lastPathComponent == "Empresa.app")
        #expect(resolver.app(for: "com.empresa") == nil)
        #expect(resolver.app(for: "com.outra.coisa") == nil)
    }

    @Test func entryRemovalItemCarriesLabel() {
        let entry = CleanupEntry(url: URL(fileURLWithPath: "/Users/teste/Library/Caches/x"), size: 4096,
                                 category: .appCaches, label: "Spotify", detail: "fsCachedData", isRecommended: true)
        #expect(entry.removalItem.label == "Spotify · fsCachedData")
        #expect(entry.removalItem.size == 4096)
    }
}
