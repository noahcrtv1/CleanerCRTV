import AppKit
import Foundation

/// Bundle ID → nome e local do app (via LaunchServices), com cache. Seguro fora da main.
public final class CleanupAppResolver: @unchecked Sendable {
    public struct App: Sendable, Hashable {
        public let name: String
        public let url: URL
    }

    public static let shared = CleanupAppResolver()

    private let lookup: @Sendable (String) -> URL?
    private let lock = NSLock()
    private var cache: [String: App?] = [:]

    /// `lookup` injetável para testes (padrão: `NSWorkspace.urlForApplication`).
    public init(lookup: @escaping @Sendable (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        self.lookup = lookup
    }

    /// Ajudantes e atualizadores sem app próprio (`com.empresa.app.ShipIt`) caem no app principal.
    public func app(for bundleID: String) -> App? {
        guard Self.looksLikeBundleID(bundleID) else { return nil }
        if let app = resolve(bundleID) { return app }
        var parts = bundleID.split(separator: ".")
        while parts.count > 3 {
            parts.removeLast()
            if let app = resolve(parts.joined(separator: ".")) { return app }
        }
        return nil
    }

    private func resolve(_ bundleID: String) -> App? {
        let key = bundleID.lowercased()
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let app: App? = lookup(bundleID).map { url in
            var name = FileManager.default.displayName(atPath: url.path)
            if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
            return App(name: name, url: url)
        }
        lock.lock()
        cache[key] = app
        lock.unlock()
        return app
    }

    /// "com.empresa.app": sem espaços nem barras, com pelo menos um ponto entre letras.
    static func looksLikeBundleID(_ name: String) -> Bool {
        guard name.contains("."), !name.hasPrefix("."), !name.hasSuffix("."),
              !name.contains(" "), !name.contains("/") else { return false }
        return true
    }
}
