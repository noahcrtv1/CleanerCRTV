import Darwin
import Foundation

/// Última barreira antes de qualquer remoção. Toda exclusão do app passa por `SafetyGuard.check`.
///
/// Regras (nesta ordem):
/// 1. Caminho absoluto, sem `..` depois de padronizado; a pasta-mãe é resolvida com `realpath`
///    (o próprio item não é seguido: remover um link apaga o link, nunca o destino).
/// 2. Nunca a raiz de algo importante: `/`, pastas do sistema, a pasta pessoal, as pastas-padrão
///    da pasta pessoal (Documentos, Biblioteca…), as subpastas-padrão de ~/Library, raízes de volumes.
/// 3. Nunca dentro de áreas intocáveis (sistema, chaves, banco de permissões).
/// 4. Só dentro das áreas permitidas: pasta pessoal, /Users/Shared, /Applications e volumes externos.
/// 5. Nunca o próprio app nem as pastas onde ele guarda dados.
public enum SafetyGuard {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case blocked(String)

        public var isAllowed: Bool { self == .allowed }
    }

    public static func check(_ url: URL) -> Verdict {
        guard url.isFileURL else { return .blocked("Não é um arquivo local") }
        let raw = url.path
        guard raw.hasPrefix("/") else { return .blocked("Caminho relativo") }
        guard let path = canonicalPath(url) else { return .blocked("Pasta não encontrada") }
        return check(canonical: path, home: canonicalHome)
    }

    /// Versão pura (testável): `path` já canônico, `home` canônico.
    static func check(canonical path: String, home: String) -> Verdict {
        if path.isEmpty || path == "/" { return .blocked("Raiz do disco") }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == ".." || $0 == "." }) { return .blocked("Caminho ambíguo") }

        if protectedExact(home: home).contains(path) { return .blocked("Pasta protegida do sistema ou da pasta pessoal") }
        for prefix in protectedPrefixes(home: home) where path == prefix || path.hasPrefix(prefix + "/") {
            return .blocked("Área protegida (\(prefix))")
        }
        // Raiz de volume externo (/Volumes/X)
        if components.count == 2, components[0] == "Volumes" { return .blocked("Raiz de um volume") }

        // Áreas permitidas
        let allowedRoots = [home, "/Users/Shared", "/Applications", "/Volumes"]
        guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
            return .blocked("Fora das áreas que o app pode limpar")
        }
        // /Volumes/Macintosh HD costuma ser link para "/" — resolvido acima pelo realpath da pasta-mãe;
        // por garantia, nada dentro de um volume que seja o disco de inicialização.
        if components.first == "Volumes", components.count >= 2 {
            let volumeRoot = "/Volumes/" + components[1]
            if let real = realpathString(volumeRoot), real == "/" { return .blocked("Disco de inicialização") }
        }
        if let own = ownPaths().first(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) {
            return .blocked("Pertence ao próprio CleanerCRTV (\(own))")
        }
        return .allowed
    }

    // MARK: - Listas

    /// Pastas da pasta pessoal que podem ter o conteúdo limpo, mas nunca ser removidas inteiras.
    public static let homeStandardFolders = [
        "Library", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public",
        "Applications", "Sites", ".Trash", ".ssh", ".config", ".local",
    ]

    /// Subpastas de ~/Library que nunca são removidas inteiras (o conteúdo pode, conforme as regras).
    public static let libraryStandardFolders = [
        "Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Logs",
        "LaunchAgents", "Mail", "Mobile Documents", "Saved Application State", "Cookies", "HTTPStorages",
        "WebKit", "CloudStorage", "Developer", "Fonts", "Safari", "Messages", "Calendars", "Photos",
        "Application Scripts", "Autosave Information", "Accounts", "Frameworks", "Services", "Sounds",
        "Input Methods", "Keyboard Layouts", "Screen Savers", "PreferencePanes", "QuickLook", "Spelling",
        "Shortcuts", "Daemon Containers", "Metadata", "Biome", "IdentityServices", "Assistant",
    ]

    static func protectedExact(home: String) -> Set<String> {
        var set: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Applications/Utilities", "/Users", "/Users/Shared",
            "/Volumes", "/private", "/private/var", "/private/tmp", "/private/etc", "/usr", "/usr/local",
            "/bin", "/sbin", "/etc", "/var", "/tmp", "/opt", "/opt/homebrew", "/cores", "/dev", "/Network",
            home,
        ]
        for folder in homeStandardFolders { set.insert(home + "/" + folder) }
        for folder in libraryStandardFolders { set.insert(home + "/Library/" + folder) }
        return set
    }

    static func protectedPrefixes(home: String) -> [String] {
        [
            "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/private/var/root",
            "/dev", "/Library/Apple", "/Applications/Safari.app",
            home + "/Library/Keychains",
            home + "/Library/Application Support/com.apple.TCC",
            home + "/Library/Application Support/MobileSync/Backup/.lock",
            home + "/.ssh",
            home + "/.gnupg",
        ]
    }

    /// O próprio app e as pastas onde ele guarda histórico e preferências.
    static func ownPaths() -> [String] {
        var paths: [String] = []
        if let bundle = realpathString(Bundle.main.bundlePath), bundle.hasSuffix(".app") { paths.append(bundle) }
        if let support = realpathString(Paths.appSupport.path) { paths.append(support) }
        return paths
    }

    // MARK: - Caminhos canônicos

    static var canonicalHome: String { realpathString(Paths.home.path) ?? Paths.home.path }

    /// Pasta-mãe resolvida com `realpath` (resolve /var → /private/var e links no meio do caminho)
    /// + o último componente sem resolver.
    static func canonicalPath(_ url: URL) -> String? {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        let parent = standardized.deletingLastPathComponent().path
        guard !name.isEmpty, name != "/", let realParent = realpathString(parent) else { return nil }
        return realParent == "/" ? "/" + name : realParent + "/" + name
    }

    static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
