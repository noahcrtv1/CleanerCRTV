import Foundation

/// Catálogo de regras do "Lixo do sistema". Caminhos relativos à pasta pessoal, conferidos no macOS 26.
public enum CleanupCatalog {
    static let day: TimeInterval = 86_400
    static let xcode = "com.apple.dt.Xcode"

    /// Todas as categorias, na ordem de exibição.
    public static let all: [CleanupCategory] = [
        appCaches, containerCaches, browsers, developer, logs, mailAttachments,
        savedState, installers, iosBackups, trash,
    ]

    public static func category(_ id: CleanupCategoryID) -> CleanupCategory {
        all.first { $0.id == id }!
    }

    // MARK: - Itens que nunca saem de uma pasta de caches

    /// Nomes (minúsculas) que nunca viram item dentro de `Caches`, mesmo sendo cache:
    /// apagar no meio do caminho perde trabalho pendente ou desliga uma proteção.
    public static let protectedCacheNames: Set<String> = [
        "cloudkit",                       // estado de sincronização do iCloud (alterações ainda não enviadas)
        "com.apple.bird",                 // iCloud Drive: envios e baixas pendentes
        "com.apple.akd",                  // Conta Apple (tokens de autenticação)
        "com.apple.appleaccountd",
        "com.apple.nsurlsessiond",        // downloads em segundo plano ainda em andamento
        "com.apple.containermanagerd",    // metadados dos contêineres dos apps
        "com.apple.homed", "com.apple.homekit", "homekit",   // app Casa
        "familycircle",                   // Compartilhamento Familiar
        "com.apple.ap.adprivacyd",        // atribuição de anúncios com privacidade
        "com.apple.safari.safebrowsing",  // proteção contra sites fraudulentos fica desligada até baixar de novo
        "com.apple.cache_delete",         // o próprio macOS controla o espaço "purgeable" por aqui
        "com.apple.applemediaservices",   // sessão da App Store / Apple Music
        "passkit", "com.apple.passd",     // Carteira e Apple Pay
        "com.apple.trustd",               // cadeia de confiança de certificados
        "com.apple.screentimeagent", "com.apple.familycontrols",   // Tempo de Uso / controles parentais
        "com.apple.mediaanalysisd",       // análise de fotos e vídeos: caro de refazer
        "com.apple.appstoreagent",        // atualizações da App Store em andamento
        "com.apple.passwords",            // app Senhas
        "com.apple.softwareupdate",       // atualizações do macOS sendo baixadas
        "com.lipenoe.cleanercrtv",        // o próprio app
    ]

    /// Prefixos (minúsculas) protegidos pelo mesmo motivo: famílias inteiras de serviços do sistema.
    public static let protectedCachePrefixes: [String] = [
        "com.apple.cloud",       // cloudd, cloudphotod (Fotos do iCloud), CloudDocs…
        "com.apple.icloud",      // iCloudHelper, buscar (searchpartyd)…
        "com.apple.findmy",
        "com.apple.security",
        "com.apple.keychain",
        "com.apple.launchservices",
        "com.apple.tcc",
        "com.apple.photo",       // biblioteca e análise do Fotos
        "com.apple.ams",         // contas da App Store e do Apple Music (amsaccountsd, amsengagementd…)
        "com.apple.fileprovider", // estado de sincronização de iCloud Drive, OneDrive, Dropbox…
        "com.google.drivefs",    // Google Drive: arquivos ainda não enviados
    ]

    /// Caminhos (relativos à pasta pessoal) que nunca viram item, nem dentro de uma pasta maior:
    /// a pasta que os contém é dividida em filhos, como acontece com as pastas ignoradas. `*` = qualquer subpasta.
    public static let protectedPaths: [String] = [
        "Library/Caches/Google/DriveFS",            // Google Drive: envios pendentes
        // Histórico local dos IDEs (JetBrains, Android Studio): versões antigas do código que você editou,
        // não é cache. Fica na pasta de sistema do IDE, dentro de Caches.
        "Library/Caches/JetBrains/*/LocalHistory",
        "Library/Caches/Google/*/LocalHistory",
    ]

    /// Contêineres da Apple liberados. Os demais são de serviços e extensões do sistema: guardam estado de
    /// sincronização e aprendizado de máquina no cache, e o ganho é pequeno. Apps de terceiros entram todos.
    public static let appleContainerAllowlist: Set<String> = [
        "com.apple.mail", "com.apple.music", "com.apple.tv", "com.apple.podcasts", "com.apple.news",
        "com.apple.stocks", "com.apple.weather", "com.apple.maps", "com.apple.appstore", "com.apple.preview",
        "com.apple.quicktimeplayerx", "com.apple.helpviewer", "com.apple.notes", "com.apple.ibooksx",
        "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote", "com.apple.freeform",
        "com.apple.garageband10", "com.apple.imovieapp", "com.apple.mobilesms", "com.apple.facetime",
        "com.apple.textedit", "com.apple.journal", "com.apple.games",
    ]

    static func acceptsContainer(_ id: String) -> Bool {
        let lower = id.lowercased()
        // Extensões de sincronização (Dropbox, OneDrive, Google Drive…) guardam no cache arquivos ainda não enviados.
        if lower.contains("fileprovider") || lower.contains("fpext") || lower.hasPrefix("com.google.drivefs") {
            return false
        }
        guard lower.hasPrefix("com.apple.") else { return true }
        return appleContainerAllowlist.contains(lower)
    }

    static let cacheFilter = CleanupFilter(excludedNames: protectedCacheNames, excludedPrefixes: protectedCachePrefixes)

    // MARK: - Categorias

    static let appCaches = CleanupCategory(
        id: .appCaches, title: "Caches de apps",
        explanation: "Arquivos temporários que os apps guardam para abrir mais rápido. São recriados quando necessário. Caches de apps abertos ficam desmarcados.",
        symbol: "shippingbox", isRecommended: true, claimOrder: 9,
        rules: [
            CleanupRule("Library/Caches", .children, owner: .itemName, label: .app,
                        filter: cacheFilter, splitsAroundClaims: true),
        ]
    )

    static let containerCaches = CleanupCategory(
        id: .containerCaches, title: "Caches em contêineres",
        explanation: "Caches de apps da App Store e de apps isolados, guardados no contêiner de cada um. Só a pasta de cache é limpa; documentos e ajustes ficam intactos.",
        symbol: "square.stack.3d.up", isRecommended: true, claimOrder: 8,
        rules: [
            CleanupRule("Library/Containers/*/Data/Library/Caches", .children, needsFullDiskAccess: true,
                        owner: .wildcard, label: .app,
                        filter: CleanupFilter(excludedNames: protectedCacheNames, excludedPrefixes: protectedCachePrefixes,
                                              wildcardAccepts: { CleanupCatalog.acceptsContainer($0) }),
                        splitsAroundClaims: true),
        ]
    )

    static let browsers: CleanupCategory = {
        var rules: [CleanupRule] = []
        let safari = CleanupOwner.fixed(["com.apple.Safari"])
        rules.append(CleanupRule("Library/Caches/com.apple.Safari", .itself, owner: safari,
                                 label: .fixed("Safari", detail: "Cache")))
        rules.append(CleanupRule("Library/Containers/com.apple.Safari/Data/Library/Caches", .children,
                                 needsFullDiskAccess: true, owner: safari, label: .browser("Safari"),
                                 filter: cacheFilter))

        // Família Chromium: o que está em ~/Library/Caches é só cache; em Application Support, apenas as
        // subpastas de cache de cada perfil. Cookies, histórico, senhas, favoritos, extensões, Local Storage
        // e IndexedDB nunca entram.
        // `rootProfile`: o Opera guarda o perfil principal direto na pasta de dados (sem "Default").
        let chromium: [(name: String, bundle: String, caches: [String], support: String, rootProfile: Bool)] = [
            ("Chrome", "com.google.Chrome", ["Google/Chrome"], "Google/Chrome", false),
            ("Edge", "com.microsoft.edgemac", ["Microsoft Edge"], "Microsoft Edge", false),
            ("Brave", "com.brave.Browser", ["BraveSoftware/Brave-Browser"], "BraveSoftware/Brave-Browser", false),
            ("Arc", "company.thebrowser.Browser", ["Arc", "company.thebrowser.Browser"], "Arc/User Data", false),
            ("Vivaldi", "com.vivaldi.Vivaldi", ["Vivaldi"], "Vivaldi", false),
            ("Opera", "com.operasoftware.Opera", ["com.operasoftware.Opera"], "com.operasoftware.Opera", true),
            ("Chromium", "org.chromium.Chromium", ["Chromium"], "Chromium", false),
        ]
        let profileCaches = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                             "Service Worker/CacheStorage", "Service Worker/ScriptCache"]
        let sharedCaches = ["GrShaderCache", "ShaderCache", "GraphiteDawnCache"]
        for browser in chromium {
            let owner = CleanupOwner.fixed([browser.bundle])
            for path in browser.caches {
                rules.append(CleanupRule("Library/Caches/\(path)", .itself, owner: owner,
                                         label: .fixed(browser.name, detail: "Cache")))
            }
            for sub in profileCaches {
                rules.append(CleanupRule("Library/Application Support/\(browser.support)/*/\(sub)", .itself,
                                         owner: owner, label: .browser(browser.name)))
            }
            for sub in sharedCaches + (browser.rootProfile ? profileCaches : []) {
                rules.append(CleanupRule("Library/Application Support/\(browser.support)/\(sub)", .itself,
                                         owner: owner, label: .browser(browser.name)))
            }
        }

        let firefox = CleanupOwner.fixed(["org.mozilla.firefox"])
        for sub in ["cache2", "startupCache", "thumbnails"] {
            rules.append(CleanupRule("Library/Caches/Firefox/Profiles/*/\(sub)", .itself, owner: firefox,
                                     label: .browser("Firefox")))
        }
        return CleanupCategory(
            id: .browsers, title: "Navegadores",
            explanation: "Cache de páginas, imagens e scripts do Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera e Firefox. Cookies, histórico, senhas, favoritos e extensões nunca são tocados.",
            symbol: "globe", isRecommended: true, claimOrder: 0, rules: rules
        )
    }()

    static let developer: CleanupCategory = {
        let xcodeOwner = CleanupOwner.fixed([xcode])
        var rules: [CleanupRule] = [
            CleanupRule("Library/Developer/Xcode/DerivedData", .children, owner: xcodeOwner, label: .derivedData),
            CleanupRule("Library/Caches/com.apple.dt.Xcode", .itself, owner: xcodeOwner,
                        label: .fixed("Xcode", detail: "Cache")),
            CleanupRule("Library/Developer/CoreSimulator/Caches", .children,
                        owner: .fixed(["com.apple.iphonesimulator", xcode]), label: .fixed("Simulador")),
            CleanupRule("Library/Developer/Xcode/UserData/Previews", .itself, isRecommended: false,
                        owner: xcodeOwner, label: .fixed("Pré-visualizações do SwiftUI"),
                        note: "Recriadas na próxima pré-visualização"),
            CleanupRule("Library/Developer/Xcode/Archives/*", .children, isRecommended: false,
                        owner: xcodeOwner, label: .xcodeArchive,
                        filter: CleanupFilter(extensions: ["xcarchive"]),
                        note: "Necessário para simbolizar falhas desta versão"),
        ]
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            rules.append(CleanupRule("Library/Developer/Xcode/\(platform) DeviceSupport", .children, isRecommended: false,
                                     owner: xcodeOwner, label: .deviceSupport(platform),
                                     filter: CleanupFilter(kind: .directories, keepNewestVersion: true),
                                     note: "Versão antiga; volta ao conectar um aparelho com ela"))
        }
        let tools: [(path: String, name: String, recommended: Bool)] = [
            ("Library/Caches/org.swift.swiftpm", "Swift Package Manager", true),
            ("Library/Caches/org.carthage.CarthageKit", "Carthage", true),
            ("Library/Caches/CocoaPods", "CocoaPods", true),
            ("Library/Caches/Homebrew", "Homebrew", true),
            (".npm/_cacache", "npm", true),
            ("Library/Caches/Yarn", "Yarn", true),
            (".bun/install/cache", "Bun", true),
            ("Library/pnpm/store", "pnpm", false),
            ("Library/Caches/pip", "pip", true),
            ("Library/Caches/deno", "Deno", true),
            (".cargo/registry/cache", "Cargo", true),
            ("Library/Caches/go-build", "Go", true),
            (".gradle/caches", "Gradle", false),
            (".m2/repository", "Maven", false),
        ]
        for tool in tools {
            rules.append(CleanupRule(tool.path, .itself, isRecommended: tool.recommended,
                                     label: .fixed(tool.name, detail: "Cache"),
                                     note: tool.recommended ? nil : "Baixado de novo no próximo build"))
        }
        rules.append(CleanupRule("Library/Caches/JetBrains", .children, owner: .fixed(["com.jetbrains.*"]),
                                 label: .fixed("JetBrains"), splitsAroundClaims: true))
        return CleanupCategory(
            id: .developer, title: "Desenvolvimento",
            explanation: "Restos de builds e caches de ferramentas (Xcode, simuladores, SwiftPM, npm, Homebrew…). Tudo é gerado ou baixado de novo quando preciso. Arquivos do Xcode e suporte a versões antigas vêm desmarcados.",
            symbol: "hammer", isRecommended: true, claimOrder: 1, rules: rules
        )
    }()

    static let logs = CleanupCategory(
        id: .logs, title: "Registros",
        explanation: "Registros de atividade e relatórios de falhas antigos. Servem para diagnosticar problemas; relatórios dos últimos 7 dias e registros gravados agora são mantidos.",
        symbol: "doc.text", isRecommended: true, claimOrder: 3,
        rules: [
            CleanupRule("Library/Logs", .children, label: .app,
                        filter: CleanupFilter(excludedNames: ["diagnosticreports"]), activeWindow: 600),
            CleanupRule("Library/Logs/DiagnosticReports", .children,
                        filter: CleanupFilter(kind: .files, minAge: 7 * day), activeWindow: 600),
            CleanupRule("Library/Logs/DiagnosticReports/Retired", .children,
                        filter: CleanupFilter(kind: .files, minAge: 7 * day), activeWindow: 600),
        ]
    )

    static let mailAttachments = CleanupCategory(
        id: .mailAttachments, title: "Anexos do Mail",
        explanation: "Cópias dos anexos que você abriu no Mail. Os originais continuam nas mensagens e são baixados de novo se precisar.",
        symbol: "paperclip", isRecommended: true, claimOrder: 2,
        rules: [
            CleanupRule("Library/Containers/com.apple.mail/Data/Library/Mail Downloads", .children,
                        needsFullDiskAccess: true, owner: .fixed(["com.apple.mail"])),
        ]
    )

    static let savedState = CleanupCategory(
        id: .savedState, title: "Estado salvo de apps",
        explanation: "Janelas que os apps reabrem ao iniciar. Limpar faz o app abrir do zero na próxima vez.",
        symbol: "macwindow.on.rectangle", isRecommended: false, claimOrder: 3,
        rules: [
            CleanupRule("Library/Saved Application State", .children, owner: .itemName, label: .app,
                        filter: CleanupFilter(extensions: ["savedstate"])),
            CleanupRule("Library/Containers/*/Data/Library/Saved Application State", .children,
                        needsFullDiskAccess: true, owner: .wildcard, label: .app,
                        filter: CleanupFilter(extensions: ["savedstate"])),
        ]
    )

    static let installers = CleanupCategory(
        id: .installers, title: "Instaladores esquecidos",
        explanation: "Imagens de disco e pacotes de instalação parados em Downloads há mais de 14 dias. Confira antes: pode ser um instalador que você quer guardar.",
        symbol: "arrow.down.app", isRecommended: false, claimOrder: 3,
        rules: [
            CleanupRule("Downloads", .children,
                        filter: CleanupFilter(extensions: ["dmg", "pkg", "mpkg", "iso", "xip"], minAge: 14 * day)),
        ]
    )

    static let iosBackups = CleanupCategory(
        id: .iosBackups, title: "Backups de iPhone e iPad",
        explanation: "Cópias de segurança locais feitas pelo Finder. Apague só se tiver outro backup, como o do iCloud.",
        symbol: "iphone", isRecommended: false, claimOrder: 3,
        rules: [
            CleanupRule("Library/Application Support/MobileSync/Backup", .children, label: .iosBackup,
                        filter: CleanupFilter(kind: .directories)),
        ]
    )

    static let trash = CleanupCategory(
        id: .trash, title: "Lixeira",
        explanation: "Itens que você já mandou para a Lixeira. Esvaziar apaga de vez e devolve o espaço.",
        symbol: "trash", isRecommended: false, claimOrder: 3,
        rules: [
            CleanupRule(".Trash", .children, filter: CleanupFilter(includeHidden: true)),
        ]
    )
}
