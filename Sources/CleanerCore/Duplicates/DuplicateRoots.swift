import Darwin
import Foundation

/// Pastas onde a busca de duplicados procura (padrão: as pastas de conteúdo da pasta pessoal).
public enum DuplicateRoots {
    public static let defaultsKey = "duplicates.roots"
    public static let standardFolderNames = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]

    /// As pastas-padrão que existem neste Mac.
    public static var defaults: [URL] {
        standardFolderNames.map { Paths.home($0) }.filter(isDirectory)
    }

    public static func load(from store: UserDefaults = .standard) -> [URL] {
        guard let saved = store.stringArray(forKey: defaultsKey) else { return defaults }
        return saved.map { URL(fileURLWithPath: $0, isDirectory: true) }.filter(isDirectory)
    }

    public static func save(_ roots: [URL], to store: UserDefaults = .standard) {
        store.set(roots.map { $0.standardizedFileURL.path }, forKey: defaultsKey)
    }

    /// Por que esta pasta não serve como ponto de partida (nil = serve).
    public static func problem(with url: URL) -> String? {
        guard isDirectory(url) else { return "Escolha uma pasta." }
        let path = canonical(url)
        let home = SafetyGuard.canonicalHome
        if path == home + "/Library" || path.hasPrefix(home + "/Library/") {
            return "A Biblioteca guarda dados de apps e fica fora da busca de duplicados."
        }
        if let values = try? url.resourceValues(forKeys: [.isPackageKey]), values.isPackage == true {
            return "Pacotes e bibliotecas (Fotos, Música…) não são abertos pela busca."
        }
        if opaqueExtensions.contains(url.pathExtension.lowercased()) {
            return "Pacotes e bibliotecas (Fotos, Música…) não são abertos pela busca."
        }
        if managedFolders(home: home).contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "Esta pasta é organizada por um app (Música, TV…) e fica fora da busca."
        }
        let inHome = path == home || path.hasPrefix(home + "/")
        let inShared = path.hasPrefix("/Users/Shared/") || path == "/Users/Shared"
        let components = path.split(separator: "/")
        let onExternal = components.count >= 2 && components[0] == "Volumes"
            && SafetyGuard.realpathString("/Volumes/" + components[1]) != "/"
        guard inHome || inShared || onExternal else {
            return "Escolha uma pasta da sua pasta pessoal ou de um disco externo."
        }
        return nil
    }

    /// Caminhos canônicos, sem repetição e sem pastas que já estão dentro de outra da lista.
    public static func normalized(_ roots: [URL]) -> [URL] {
        let paths = roots.map(canonical).sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in paths where !kept.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
            kept.append(path)
        }
        return kept.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Regras compartilhadas com o scanner

    /// Pacotes que nunca são abertos, mesmo quando o sistema não os marca como pacote.
    static let opaqueExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "theater", "fcpbundle", "logicx", "band", "lrdata", "lrlibrary", "cocatalog",
        "app", "framework", "bundle", "plugin", "kext", "xcodeproj", "xcworkspace", "xcassets",
    ]

    /// Pastas de mídia gerenciadas por apps: tirar um arquivo de lá deixa a biblioteca do app com buracos.
    static func managedFolders(home: String) -> [String] {
        [
            home + "/Music/Music/Media.localized", home + "/Music/Music/Media",
            home + "/Music/iTunes/iTunes Media", home + "/Music/Audio Music Apps",
            home + "/Movies/TV/Media.localized", home + "/Movies/TV/Media",
            home + "/Pictures/Photo Booth Library",
        ]
    }

    static func canonical(_ url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        return SafetyGuard.realpathString(standardized) ?? standardized
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
