import CoreServices
import Darwin
import Foundation
import Security

/// Lista os apps instalados em /Applications e ~/Applications (mais um nível de subpastas).
public enum UninstallInventory {
    public static let selfBundleID = "com.lipenoe.cleanercrtv"

    public static func defaultRoots(home: URL = Paths.home) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Pacotes .app nas raízes e em subpastas comuns de um nível ("/Applications/Adobe X/").
    /// Não entra em pacotes nem segue links.
    public static func bundleURLs(in roots: [URL], filter: UninstallFilter) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !filter.isExcluded(url), seen.insert(path).inserted else { return }
            found.append(url)
        }
        for root in roots where !filter.isExcluded(root) {
            for entry in children(of: root) {
                if entry.isApp {
                    add(entry.url)
                } else if entry.isPlainFolder, !filter.isExcluded(entry.url) {
                    for inner in children(of: entry.url) where inner.isApp { add(inner.url) }
                }
            }
        }
        return found
    }

    /// Lê tudo de um app menos o tamanho (que é medido à parte, por ser lento).
    public static func readApp(at url: URL, filter: UninstallFilter = .live()) -> UninstallApp {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        var info = readPlist(contents.appendingPathComponent("Info.plist"))
        // Apps de iPhone/iPad no Mac: Info.plist dentro de WrappedBundle.
        if info == nil { info = readPlist(url.appendingPathComponent("WrappedBundle/Info.plist")) }
        let plist = info ?? [:]

        let bundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uninstallNonEmpty
        let fileStem = url.deletingPathExtension().lastPathComponent
        var display = FileManager.default.displayName(atPath: url.path)
        if display.lowercased().hasSuffix(".app") { display = String(display.dropLast(4)) }
        let name = display.uninstallNonEmpty ?? fileStem
        let version = ((plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String))?.uninstallNonEmpty
        let aliases = [fileStem, plist["CFBundleName"] as? String, plist["CFBundleDisplayName"] as? String]
            .compactMap { $0?.uninstallNonEmpty }
            .filter { $0 != name }

        let fm = FileManager.default
        let isAppStore = fm.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path)
            || fm.fileExists(atPath: url.appendingPathComponent("Wrapper/iTunesMetadata.plist").path)
        let lowerID = bundleID?.lowercased()
        let isApple = lowerID?.hasPrefix("com.apple.") ?? false
        let isSelf = lowerID == selfBundleID
            || url.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path

        var blockReason: String?
        if isSelf {
            blockReason = "É o próprio CleanerCRTV."
        } else if isApple {
            blockReason = "Apps da Apple fazem parte do macOS e não são removidos por aqui."
        } else if filter.checksSafety, case .blocked(let reason) = SafetyGuard.check(url) {
            blockReason = "Protegido: \(reason)."
        }

        let signing = signingInfo(of: url)
        let embedded = embeddedBundles(in: url)
        var groups = signing.groups
        // Extensões e itens de início costumam declarar grupos próprios.
        for bundle in embedded.filter({ ["appex", "app"].contains($0.url.pathExtension.lowercased()) }).prefix(16) {
            groups.append(contentsOf: signingInfo(of: bundle.url).groups)
        }

        return UninstallApp(
            url: url, name: name, bundleID: bundleID, version: version, teamID: signing.team,
            lastUsed: spotlightLastUsed(url), isAppStore: isAppStore, isApple: isApple, isSelf: isSelf,
            embeddedBundleIDs: embedded.map(\.id), aliases: aliases, appGroups: groups, stamp: stamp(of: url),
            blockReason: blockReason
        )
    }

    /// Descobre e lê os apps (rápido: plist, assinatura e Spotlight; sem medir tamanho).
    /// `progress(feitos, total)` vem de várias tarefas, fora da main.
    @concurrent
    public static func discover(
        roots: [URL] = defaultRoots(),
        filter: UninstallFilter = .live(),
        concurrency: Int = 8,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [UninstallApp] {
        let urls = bundleURLs(in: roots, filter: filter)
        progress?(0, urls.count)
        let apps = await UninstallConcurrency.map(urls, limit: concurrency, onEach: progress) { readApp(at: $0, filter: filter) }
        return apps.compactMap { $0 }
    }

    /// Mede o tamanho de cada pacote (em paralelo, limitado). `onSize` é chamado a cada app medido.
    @concurrent
    public static func measureSizes(of urls: [URL], concurrency: Int = 4,
                                    onSize: @escaping @Sendable (URL, Int64) -> Void) async {
        _ = await UninstallConcurrency.map(urls, limit: concurrency) { url in
            let size = FileSizer.allocatedSize(of: url, isCancelled: { Task.isCancelled })
            if !Task.isCancelled { onSize(url, size) }
            return size
        }
    }

    // MARK: - Detalhes

    /// Equipe e grupos de app da assinatura (só lê; não valida a assinatura).
    static func signingInfo(of url: URL) -> (team: String?, groups: [String]) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, []) }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, []) }
        let team = (dict[kSecCodeInfoTeamIdentifier as String] as? String)?.uninstallNonEmpty
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = (entitlements?["com.apple.security.application-groups"] as? [String]) ?? []
        return (team, groups.filter { !$0.isEmpty })
    }

    /// Último uso registrado pelo Spotlight (abrir pelo Finder, Dock, Launchpad…).
    static func spotlightLastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Ajudantes, itens de início, serviços XPC e extensões dentro do pacote (identificador e caminho).
    static func embeddedBundles(in app: URL) -> [(id: String, url: URL)] {
        let folders = ["Contents/Library/LoginItems", "Contents/XPCServices", "Contents/PlugIns", "Contents/Helpers",
                       "Contents/Frameworks", "Contents/MacOS", "Contents/Library/Helpers"]
        let extensions: Set<String> = ["app", "xpc", "appex"]
        var found: [(id: String, url: URL)] = []
        var seen = Set<String>()
        for folder in folders {
            let dir = app.appendingPathComponent(folder, isDirectory: true)
            for entry in children(of: dir) where extensions.contains(entry.url.pathExtension.lowercased()) && !entry.isSymlink {
                let plist = readPlist(entry.url.appendingPathComponent("Contents/Info.plist"))
                if let id = (plist?["CFBundleIdentifier"] as? String)?.uninstallNonEmpty, seen.insert(id).inserted {
                    found.append((id, entry.url))
                }
                if found.count >= 64 { return found.sorted { $0.id < $1.id } }
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    /// Identidade do pacote: muda quando ele é substituído ou atualizado.
    static func stamp(of url: URL) -> String {
        var st = stat()
        var plist = stat()
        _ = lstat(url.path, &st)
        _ = lstat(url.appendingPathComponent("Contents/Info.plist").path, &plist)
        return "\(st.st_ino)-\(st.st_mtimespec.tv_sec)-\(plist.st_mtimespec.tv_sec)-\(plist.st_size)"
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    struct Child {
        let url: URL
        let isDirectory: Bool
        let isPackage: Bool
        let isSymlink: Bool

        var isApp: Bool { isDirectory && !isSymlink && url.pathExtension.lowercased() == "app" }
        var isPlainFolder: Bool { isDirectory && !isSymlink && !isPackage }
    }

    static func children(of folder: URL) -> [Child] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Child(url: url, isDirectory: values?.isDirectory ?? false, isPackage: values?.isPackage ?? false,
                         isSymlink: values?.isSymbolicLink ?? false)
        }
    }
}

private extension String {
    var uninstallNonEmpty: String? { isEmpty ? nil : self }
}
