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

    /// Pastas que sumiram (disco externo desconectado) continuam na lista; a busca só as pula.
    public static func load(from store: UserDefaults = .standard) -> [URL] {
        guard let saved = store.stringArray(forKey: defaultsKey) else { return defaults }
        return saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// A pasta existe agora (um disco externo pode estar desconectado)?
    public static func isAvailable(_ url: URL) -> Bool { isDirectory(url) }

    public static func save(_ roots: [URL], to store: UserDefaults = .standard) {
        store.set(roots.map { $0.standardizedFileURL.path }, forKey: defaultsKey)
    }

    /// Por que esta pasta não serve como ponto de partida (nil = serve).
    public static func problem(with url: URL) -> String? {
        guard isDirectory(url) else { return "Escolha uma pasta." }
        let path = canonical(url)
        let home = SafetyGuard.canonicalHome
        let cloud = [home + "/Library/Mobile Documents", home + "/Library/CloudStorage"]
        if cloud.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "Pastas de nuvem (iCloud Drive, Dropbox…) ficam fora da busca: ler os arquivos faria o Mac baixá-los."
        }
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
        // Um compartilhamento de rede pode ser o próprio Mac: o mesmo arquivo apareceria duas vezes como
        // "cópia" e remover uma apagaria a única que existe.
        let volume = try? URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey])
        if volume?.volumeIsLocal == false { return "Pastas de rede ficam fora da busca de duplicados." }
        if volume?.volumeIsReadOnly == true { return "Este disco é somente leitura: nada poderia ser removido dele." }
        return nil
    }

    /// "Ignorar sempre" só para pastas comuns: nunca a pasta pessoal, as pastas-padrão dela (Documentos,
    /// Downloads…), a raiz de um disco ou /Users/Shared — a exclusão vale para todas as varreduras do app
    /// e sai de um clique no menu, sem confirmação.
    public static func canBeIgnored(_ folder: URL) -> Bool {
        let path = canonical(folder)
        let home = SafetyGuard.canonicalHome
        if path == home || SafetyGuard.homeStandardFolders.contains(where: { path == home + "/" + $0 }) { return false }
        return path.split(separator: "/").count > 2
    }

    /// Junta uma pasta à lista, mantendo a ordem: recusa a inválida ou já coberta por outra
    /// e tira as que ficam dentro da nova.
    public static func adding(_ url: URL, to roots: [URL]) -> (roots: [URL], problem: String?) {
        if let problem = problem(with: url) { return (roots, problem) }
        let path = canonical(url)
        let existing = roots.map(canonical)
        if let parent = existing.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            let name = displayName(URL(fileURLWithPath: path))
            return (roots, parent == path
                    ? "“\(name)” já está na busca."
                    : "“\(name)” já está na busca, dentro de “\(displayName(URL(fileURLWithPath: parent)))”.")
        }
        var result = zip(roots, existing).filter { !$0.1.hasPrefix(path + "/") }.map(\.0)
        result.append(URL(fileURLWithPath: path, isDirectory: true))
        return (result, nil)
    }

    /// Nome como o Finder mostra (ex.: "Documentos").
    public static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
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
        "app", "framework", "bundle", "plugin", "kext", "xcodeproj", "xcworkspace", "xcassets", "xcarchive",
        // Imagens de disco em bandas e máquinas virtuais: bandas iguais (zeradas) não são cópias descartáveis.
        "sparsebundle", "pvm", "pvmp", "vmwarevm", "utm",
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
