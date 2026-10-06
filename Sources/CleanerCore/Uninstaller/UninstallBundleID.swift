import Foundation

/// Regras sobre identificadores de pacote (com.empresa.app). Tudo em minúsculas.
public enum UninstallBundleID {
    /// Parece um identificador reverso: ≥ 3 partes de letras/dígitos/hífen, a primeira só letras (com, org, io…).
    public static func looksLikeBundleID(_ key: String) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        let first = parts[0]
        return (2...10).contains(first.count) && first.allSatisfy(\.isLetter)
    }

    /// `key` é `id` ou algo de dentro dele (com.foo.app → com.foo.app.helper). Nunca por pedaço de nome.
    public static func isSame(_ key: String, orChildOf id: String) -> Bool {
        key == id || key.hasPrefix(id + ".")
    }

    /// Dono mais específico de `key` entre `ids` (o identificador mais longo que casa).
    public static func owner(of key: String, among ids: some Sequence<String>) -> String? {
        var best: String?
        for id in ids where isSame(key, orChildOf: id) {
            if best == nil || id.count > best!.count { best = id }
        }
        return best
    }

    /// Fabricante: as duas primeiras partes (três em domínios de hospedagem, como io.github.fulano).
    public static func vendor(of key: String) -> String {
        let parts = key.split(separator: ".")
        guard parts.count >= 2 else { return key }
        let count = parts.count >= 3 && hostingDomains.contains(String(parts[1])) ? 3 : 2
        return parts.prefix(count).joined(separator: ".")
    }

    /// Componentes do sistema, bibliotecas embutidas em muitos apps, atualizadores e agentes de gestão.
    /// Nunca viram "resto de app removido" nem resto de outro app.
    public static func isShared(_ key: String) -> Bool {
        if sharedPrefixes.contains(where: { isSame(key, orChildOf: $0) }) { return true }
        // "groups.com.apple.x", "foo.com.apple.y": qualquer coisa com com.apple no meio é da Apple.
        let parts = key.split(separator: ".")
        return parts.indices.dropLast().contains { parts[$0] == "com" && parts[$0 + 1] == "apple" }
    }

    static let hostingDomains: Set<String> = [
        "github", "gitlab", "sourceforge", "bitbucket", "codeberg", "googlecode", "herokuapp", "netlify", "vercel",
    ]

    static let sharedPrefixes: [String] = [
        // Apple
        "com.apple", "group.com.apple", "groups.com.apple", "systemgroup.com.apple", "apple",
        "is.workflow", "com.shazam",
        // próprio app
        UninstallInventory.selfBundleID,
        // bibliotecas e relatórios de falha embutidos
        "org.sparkle-project", "com.crashlytics", "io.fabric", "com.plausiblelabs", "net.hockeyapp", "io.sentry",
        "com.bugsnag", "com.github.electron", "org.chromium", "com.electron",
        // atualizadores e serviços compartilhados entre apps do mesmo fabricante
        "com.google.keystone", "com.google.googleupdater", "com.google.softwareupdate",
        "com.microsoft.autoupdate", "com.microsoft.autoupdate2", "com.microsoft.office", "com.microsoft.shared",
        "com.microsoft.errorreporting", "com.microsoft.edgeupdater", "com.microsoft.oneauth", "com.microsoft.identity",
        "com.adobe.acc", "com.adobe.ccxprocess", "com.adobe.armdc", "com.adobe.agsservice", "com.adobe.adobeipcbroker",
        "com.adobe.ngl", "com.adobe.dunamis", "com.adobe.crashreporter", "com.adobe.accmac", "com.adobe.ccd",
        "com.oracle.java", "com.oracle.oss", "org.python", "org.gpgtools", "org.macports", "sh.brew", "org.cocoapods",
        // partes do sistema com identificador fora de com.apple
        "org.cups", "edu.mit.kerberos", "org.openldap", "org.openssh", "com.openssh", "org.swift", "org.llvm", "org.ntp",
        // gestão e segurança corporativa (rodam como serviço, sem app)
        "com.jamf", "com.jamfsoftware", "com.kandji", "com.mosyle", "com.addigy", "com.crowdstrike", "com.sentinelone",
        "com.zscaler", "com.paloaltonetworks", "com.cisco", "com.sophos", "com.microsoft.wdav", "com.microsoft.intune",
        "com.googlecode.munki", "com.github.macadmins",
    ]

    /// Nomes de pasta genéricos demais para casar com o nome de um app.
    static let genericNames: Set<String> = [
        "app", "apps", "application", "applications", "support", "library", "data", "cache", "caches", "log", "logs",
        "temp", "tmp", "default", "shared", "common", "helper", "helpers", "updater", "update", "updates", "plugins",
        "plug-ins", "extensions", "crashreporter", "crashreports", "diagnosticreports", "diagnostics", "settings",
        "preferences", "config", "backup", "backups", "documents", "downloads", "desktop", "icloud", "fonts",
        "installer", "setup", "uninstaller", "uninstall", "launcher", "agent", "service", "services", "daemon",
        "tools", "utilities", "utility", "google", "microsoft", "adobe", "apple", "mozilla", "jetbrains", "autodesk",
        "python", "java", "node", "npm", "ruby", "git", "homebrew", "unity", "electron", "chromium",
    ]
}
