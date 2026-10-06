import Foundation

/// Identificadores de coisas instaladas que não entram no inventário de apps: apps em pastas mais fundas,
/// plug-ins (áudio, Quick Look, painéis…), ajudantes privilegiados e serviços do launchd.
/// Servem só para os restos de apps removidos: quem tem algo disso instalado não é "removido".
public enum UninstallKnownBundles {
    public struct Snapshot: Sendable, Hashable {
        /// Identificadores de pacote (minúsculas).
        public var ids: Set<String>
        /// Contêineres de grupo declarados nas assinaturas (minúsculas).
        public var groups: Set<String>

        public init(ids: Set<String> = [], groups: Set<String> = []) {
            self.ids = Set(ids.map { $0.lowercased() })
            self.groups = Set(groups.map { $0.lowercased() })
        }
    }

    /// Pastas de plug-ins, relativas a /Library e ~/Library. Só o primeiro nível de cada uma.
    static let pluginFolders = [
        "QuickLook", "PreferencePanes", "Screen Savers", "Input Methods", "Services", "Spotlight", "Internet Plug-Ins",
        "Mail/Bundles", "ColorPickers", "Contextual Menu Items", "Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST",
        "Audio/Plug-Ins/VST3", "Audio/Plug-Ins/HAL", "Audio/MIDI Drivers", "CoreMediaIO/Plug-Ins/DAL", "Video/Plug-Ins",
        "Extensions", "Frameworks", "Printers", "Image Capture/Devices", "Application Support/Adobe/Plug-Ins",
    ]

    /// Lê tudo de uma vez (listagens, Info.plist e assinaturas; nada é medido).
    /// `systemApps`: apps do macOS (/System/Applications), que não entram no inventário mas usam grupos.
    public static func collect(
        home: URL = Paths.home,
        appRoots: [URL]? = nil,
        systemApps: [URL] = [URL(fileURLWithPath: "/System/Applications", isDirectory: true)],
        systemLibrary: URL? = URL(fileURLWithPath: "/Library")
    ) -> Snapshot {
        var ids = Set<String>()
        var groups = Set<String>()
        for root in (appRoots ?? UninstallInventory.defaultRoots(home: home)) + systemApps {
            for app in deepApps(in: root, maxDepth: 4) {
                if let id = bundleID(of: app) { ids.insert(id) }
                groups.formUnion(UninstallInventory.signingInfo(of: app).groups.map { $0.lowercased() })
            }
        }
        let libraries = [systemLibrary, home.appendingPathComponent("Library", isDirectory: true)].compactMap { $0 }
        for library in libraries {
            for folder in pluginFolders {
                ids.formUnion(bundleIDs(in: library.appendingPathComponent(folder, isDirectory: true)))
            }
        }
        if let systemLibrary {
            // Ajudantes privilegiados têm o identificador como nome de arquivo.
            let helpers = systemLibrary.appendingPathComponent("PrivilegedHelperTools", isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: helpers.path)) ?? [] {
                ids.insert(name.lowercased())
            }
            for folder in ["LaunchAgents", "LaunchDaemons"] {
                let dir = systemLibrary.appendingPathComponent(folder, isDirectory: true)
                for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    ids.insert(url.deletingPathExtension().lastPathComponent.lowercased())
                    if let label = UninstallLibraryIndex.readAgent(url)?.label { ids.insert(label.lowercased()) }
                }
            }
        }
        return Snapshot(ids: ids.filter(UninstallBundleID.looksLikeBundleID), groups: groups)
    }

    /// Apps até `maxDepth` níveis abaixo de `root`, sem entrar em pacotes.
    static func deepApps(in root: URL, maxDepth: Int) -> [URL] {
        var apps: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return apps }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 20_000 { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if url.pathExtension.lowercased() == "app" {
                apps.append(url)
                walker.skipDescendants()
            } else if walker.level >= maxDepth {
                walker.skipDescendants()
            }
        }
        return apps
    }

    /// Identificadores dos pacotes no primeiro nível de `folder`.
    static func bundleIDs(in folder: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return Set(urls.prefix(2_000).compactMap(bundleID(of:)))
    }

    static func bundleID(of bundle: URL) -> String? {
        for rel in ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"] {
            if let plist = UninstallInventory.readPlist(bundle.appendingPathComponent(rel)),
               let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty {
                return id.lowercased()
            }
        }
        return nil
    }
}
