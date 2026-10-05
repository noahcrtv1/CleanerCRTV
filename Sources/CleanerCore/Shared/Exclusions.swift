import Foundation

/// Pastas que o usuário mandou ignorar (Ajustes ▸ Ignorar). Valem para todas as varreduras.
public enum Exclusions {
    public static let defaultsKey = "excludedPaths"

    public static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: defaultsKey) }
    }

    public static func add(_ url: URL) { paths = paths + [url.standardizedFileURL.path] }
    public static func remove(_ path: String) { paths = paths.filter { $0 != path } }

    public static func isExcluded(_ url: URL) -> Bool {
        isExcluded(path: url.standardizedFileURL.path, in: paths)
    }

    static func isExcluded(path: String, in list: [String]) -> Bool {
        list.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
