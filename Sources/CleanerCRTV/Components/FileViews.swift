import AppKit
import CleanerCore
import Quartz
import SwiftUI

/// Ícone do Finder para um caminho (com cache).
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Ações de arquivo comuns a todos os módulos.
@MainActor
enum Reveal {
    static func inFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func inFinder(_ url: URL) { inFinder([url]) }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Pré-visualização do Quick Look (espaço do Finder).
    static func quickLook(_ urls: [URL]) {
        QuickLookCoordinator.shared.show(urls)
    }

    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

/// Menu de contexto padrão para um arquivo: Quick Look, Finder, copiar caminho, ignorar.
struct FileContextMenu: View {
    let url: URL
    var onIgnore: (() -> Void)?

    var body: some View {
        Button("Quick Look") { Reveal.quickLook([url]) }
        Button("Mostrar no Finder") { Reveal.inFinder(url) }
        Button("Copiar caminho") { Reveal.copyPath(url) }
        if let onIgnore {
            Divider()
            Button("Ignorar sempre esta pasta") {
                Exclusions.add(url)
                onIgnore()
            }
        }
    }
}

@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
