import Foundation

/// Pastas conhecidas. O app não roda em sandbox: `home` é a pasta pessoal de verdade.
public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let library = home.appendingPathComponent("Library", isDirectory: true)

    public static func library(_ subpath: String) -> URL {
        library.appendingPathComponent(subpath, isDirectory: true)
    }

    public static func home(_ subpath: String) -> URL {
        home.appendingPathComponent(subpath, isDirectory: true)
    }

    /// ~/Library/Application Support/CleanerCRTV (criada sob demanda).
    public static let appSupport: URL = {
        let url = library("Application Support/CleanerCRTV")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static let trash = home(".Trash")
}
