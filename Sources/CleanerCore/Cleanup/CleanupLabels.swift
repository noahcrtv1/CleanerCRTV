import Foundation

/// Rótulos amigáveis e leitura de metadados (versões, backups, arquivos do Xcode).
enum CleanupLabels {
    struct Labeled {
        var label: String
        var detail: String?
        var date: Date?
    }

    /// `bundleID` = dono principal (quando houver); `app` = app resolvido para ele.
    static func label(for candidate: CleanupCandidate, bundleID: String?, app: CleanupAppResolver.App?) -> Labeled {
        let url = candidate.url
        let name = url.lastPathComponent
        let relative = candidate.relativeComponents
        let isChildren = candidate.rule.mode == .children

        switch candidate.rule.label {
        case .name:
            return Labeled(label: name, detail: relative.count > 1 ? relative.dropLast().joined(separator: "/") : nil)

        case .app:
            if case .wildcard = candidate.rule.owner {
                // Contêiner: o app é o dono; o detalhe é o que está dentro da pasta de cache.
                return Labeled(label: app?.name ?? candidate.captures.first ?? name,
                               detail: relative.joined(separator: "/"))
            }
            let top = relative.first ?? name
            let rest = relative.count > 1 ? relative.dropFirst().joined(separator: "/") : nil
            return Labeled(label: app?.name ?? stripSavedState(top), detail: rest)

        case .fixed(let title, let detail):
            return Labeled(label: title, detail: detail ?? (isChildren ? relative.joined(separator: "/") : nil))

        case .browser(let browser):
            if isChildren { return Labeled(label: browser, detail: relative.joined(separator: "/")) }
            let what = browserCacheName(pattern: candidate.rule.pattern)
            guard let profile = candidate.captures.first else { return Labeled(label: browser, detail: what) }
            return Labeled(label: browser, detail: "\(what) · \(profileName(profile))")

        case .derivedData:
            if name == "ModuleCache.noindex" { return Labeled(label: "Cache de módulos", detail: "DerivedData") }
            return Labeled(label: derivedDataProject(name), detail: "DerivedData")

        case .xcodeArchive:
            let info = plist(url.appendingPathComponent("Info.plist"))
            let title = info?["Name"] as? String ?? url.deletingPathExtension().lastPathComponent
            let properties = info?["ApplicationProperties"] as? [String: Any]
            let version = properties?["CFBundleShortVersionString"] as? String
            let date = info?["CreationDate"] as? Date
            let parts = [version.map { "versão \($0)" }, date.map(shortDate) ?? candidate.captures.first]
            return Labeled(label: title, detail: parts.compactMap { $0 }.joined(separator: " · "), date: date)

        case .deviceSupport(let platform):
            let version = self.version(in: name).map { $0.map(String.init).joined(separator: ".") }
            return Labeled(label: "\(platform) \(version ?? name)", detail: name)

        case .iosBackup:
            let info = plist(url.appendingPathComponent("Info.plist"))
            let device = (info?["Device Name"] as? String) ?? (info?["Display Name"] as? String) ?? "Backup sem nome"
            let date = info?["Last Backup Date"] as? Date
            let system = (info?["Product Version"] as? String).map { "iOS \($0)" }
            let parts = [system, date.map(shortDate)]
            let detail = parts.compactMap { $0 }.joined(separator: " · ")
            return Labeled(label: device, detail: detail.isEmpty ? nil : detail, date: date)
        }
    }

    /// "com.empresa.app.savedState" → "com.empresa.app" (é o bundle ID do dono).
    static func stripSavedState(_ name: String) -> String {
        let suffix = ".savedState"
        guard name.lowercased().hasSuffix(suffix.lowercased()), name.count > suffix.count else { return name }
        return String(name.dropLast(suffix.count))
    }

    /// "…/*/Service Worker/CacheStorage" → "Service Worker/CacheStorage".
    static func browserCacheName(pattern: String) -> String {
        if let range = pattern.range(of: "/*/", options: .backwards) {
            return String(pattern[range.upperBound...])
        }
        return (pattern as NSString).lastPathComponent
    }

    /// Perfil do Firefox ("ab12cd.default-release") → "default-release"; Chromium fica como está.
    static func profileName(_ folder: String) -> String {
        guard !folder.contains(" "), let dot = folder.firstIndex(of: "."), folder.index(after: dot) < folder.endIndex else {
            return folder
        }
        return String(folder[folder.index(after: dot)...])
    }

    /// "MeuApp-abcdefghijklmnopqrstuvwxyzab" → "MeuApp".
    static func derivedDataProject(_ name: String) -> String {
        guard let dash = name.lastIndex(of: "-") else { return name }
        let hash = name[name.index(after: dash)...]
        guard hash.count >= 20, hash.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return name }
        return String(name[..<dash])
    }

    // MARK: - Versões

    /// Primeiro trecho numérico do nome: "iPhone16,1 17.5.1 (21F90)" → [17, 5, 1].
    static func version(in name: String) -> [Int]? {
        for token in name.split(separator: " ") {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            if !parts.isEmpty, numbers.count == parts.count { return numbers }
        }
        return nil
    }

    /// Compara versões completando com zeros ([17, 5] == [17, 5, 0]).
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // MARK: - Auxiliares

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return object as? [String: Any]
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "pt_BR")))
    }
}
