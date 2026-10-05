import Foundation

/// Uso de um volume, com o mesmo "disponível" do Finder (inclui espaço purgeable).
public struct VolumeUsage: Sendable, Equatable {
    public var name: String
    public var total: Int64
    /// Disponível para uso importante (livre + purgeable que o macOS libera sozinho).
    public var available: Int64
    /// Livre de verdade agora (sem contar purgeable).
    public var free: Int64

    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    public var purgeable: Int64 { max(0, available - free) }

    public static func of(_ url: URL) -> VolumeUsage {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let values = try? url.resourceValues(forKeys: keys)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        return VolumeUsage(name: values?.volumeLocalizedName ?? "Disco", total: total,
                           available: max(important, free), free: free)
    }

    public static func startup() -> VolumeUsage { of(URL(fileURLWithPath: "/")) }

    /// Volumes montados visíveis (disco interno + externos), para escolher no Mapa do disco.
    public static func mountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                                              options: [.skipHiddenVolumes]) ?? []
    }
}
