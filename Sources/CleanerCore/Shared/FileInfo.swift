import Foundation

/// Metadados básicos de um item, lidos sem seguir links.
public struct FileInfo: Sendable, Hashable {
    public let url: URL
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isPackage: Bool
    public let modified: Date?
    public let accessed: Date?
    public let created: Date?

    public static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .contentModificationDateKey, .contentAccessDateKey, .creationDateKey,
    ]

    public init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        self.url = url
        isDirectory = values.isDirectory ?? false
        isSymlink = values.isSymbolicLink ?? false
        isPackage = values.isPackage ?? false
        modified = values.contentModificationDate
        accessed = values.contentAccessDate
        created = values.creationDate
    }

    /// Data mais recente entre abertura e modificação (o que o usuário entende por "usado").
    public var lastUsed: Date? {
        switch (accessed, modified) {
        case let (a?, m?): max(a, m)
        case let (a?, nil): a
        case let (nil, m?): m
        default: nil
        }
    }
}
