import Foundation

/// Tamanhos no mesmo padrão do Finder (base 1000).
public enum ByteSize {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.isAdaptive = true
        return f
    }()
    private static let lock = NSLock()

    public static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "Zero KB" }
        lock.lock(); defer { lock.unlock() }
        return formatter.string(fromByteCount: bytes)
    }
}

public extension Int64 {
    /// `1_234_567.formattedBytes` → "1,2 MB"
    var formattedBytes: String { ByteSize.string(self) }
}
