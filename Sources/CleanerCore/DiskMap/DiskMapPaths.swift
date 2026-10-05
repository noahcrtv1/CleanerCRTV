import Darwin
import Foundation

/// Caminhos do disco de inicialização.
///
/// O macOS separa o volume do sistema ("/", selado) do volume de dados (/System/Volumes/Data);
/// /Users, /Applications, /Library, /private… são firmlinks para o volume de dados.
/// O mapa varre o volume de dados, mas mostra e age sempre pelo caminho de sempre (/Users/x),
/// que é o que o SafetyGuard entende (ele bloqueia tudo em /System).
public enum DiskMapPaths {
    public static let dataVolumePrefix = "/System/Volumes/Data"

    /// Caminho como o usuário conhece: tira o prefixo do volume de dados. Função pura.
    public static func displayPath(forPhysicalPath path: String) -> String {
        if path == dataVolumePrefix || path == dataVolumePrefix + "/" { return "/" }
        if path.hasPrefix(dataVolumePrefix + "/") { return String(path.dropFirst(dataVolumePrefix.count)) }
        return path
    }

    /// URL para Finder, Quick Look e remoção. Quando o caminho foi traduzido, só vale se o caminho
    /// traduzido existir e for o mesmo objeto (mesmo dispositivo e inode); senão, nil.
    public static func actionURL(forPhysicalPath path: String) -> URL? {
        let shown = displayPath(forPhysicalPath: path)
        guard shown != path else {
            return FileSizer.exists(URL(fileURLWithPath: path)) ? URL(fileURLWithPath: path) : nil
        }
        var physical = stat(), mapped = stat()
        guard lstat(path, &physical) == 0, lstat(shown, &mapped) == 0,
              physical.st_dev == mapped.st_dev, physical.st_ino == mapped.st_ino else { return nil }
        return URL(fileURLWithPath: shown)
    }

    /// `path` é exatamente um ponto de montagem?
    static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == path
    }

    /// Caminho absoluto sem links (a raiz do mapa nunca é um link).
    static func resolved(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
}

/// Extensões de pastas que o Finder mostra como um item só (apps, bibliotecas, projetos…).
enum DiskMapPackages {
    static let extensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "component", "prefpane", "saver",
        "qlgenerator", "mdimporter", "wdgt", "photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary",
        "imovielibrary", "tvlibrary", "theater", "fcpbundle", "logicx", "band", "xcodeproj", "xcworkspace",
        "xcarchive", "playground", "xcappdata", "docarchive", "dsym", "rtfd", "pages", "numbers", "key",
        "pkg", "mpkg", "sparsebundle", "scptd", "workflow", "wflow", "vst", "vst3", "aaxplugin", "lpdf",
        "nib", "storyboardc", "momd", "fcpxbundle", "musiclibrary",
    ]

    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 22 else { return false }
        return extensions.contains(ext.lowercased())
    }
}
