import AppKit
import Foundation

/// Apps abertos agora (para avisar antes de limpar cache ou desinstalar um app em uso).
public enum RunningApps {
    @MainActor public static var bundleIdentifiers: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    @MainActor public static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Pede para o app fechar (como ⌘Q). Devolve false se não estava aberto.
    @MainActor @discardableResult
    public static func quit(bundleID: String) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        return !apps.isEmpty
    }
}
