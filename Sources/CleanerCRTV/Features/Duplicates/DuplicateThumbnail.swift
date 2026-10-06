import AppKit
import CleanerCore
import QuickLookThumbnailing
import SwiftUI

/// Miniaturas do Quick Look com cache (as falhas também ficam guardadas para não tentar de novo).
@MainActor
final class DuplicateThumbnailCache {
    static let shared = DuplicateThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private var failed = Set<String>()

    private init() { cache.countLimit = 600 }

    private func key(_ url: URL, _ size: CGFloat) -> String { "\(Int(size))|\(url.path)" }

    func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size) as NSString)
    }

    func load(_ url: URL, size: CGFloat, scale: CGFloat) async -> NSImage? {
        let key = key(url, size)
        if let image = cache.object(forKey: key as NSString) { return image }
        guard !failed.contains(key) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        let generator = QLThumbnailGenerator.shared
        let representation = try? await withTaskCancellationHandler {
            try await generator.generateBestRepresentation(for: request)
        } onCancel: {
            generator.cancel(request)
        }
        if Task.isCancelled { return nil }
        guard let image = representation?.nsImage else {
            if failed.count > 5_000 { failed.removeAll() }
            failed.insert(key)
            return nil
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// Miniatura do conteúdo (imagem, vídeo, PDF…) com o ícone do Finder enquanto carrega ou quando não há.
struct DuplicateThumbnailView: View {
    let url: URL
    var size: CGFloat = 36
    /// false = só o ícone (tipos sem miniatura de conteúdo).
    var loadsContent = true
    var cornerRadius: CGFloat?
    var fit = false

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    init(url: URL, size: CGFloat = 36, loadsContent: Bool = true, cornerRadius: CGFloat? = nil, fit: Bool = false) {
        self.url = url
        self.size = size
        self.loadsContent = loadsContent
        self.cornerRadius = cornerRadius
        self.fit = fit
        // Já em cache: aparece no primeiro quadro, sem piscar o ícone.
        _image = State(initialValue: loadsContent ? DuplicateThumbnailCache.shared.cached(url, size: size) : nil)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: fit ? .fit : .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.16, style: .continuous))
                    .transition(.opacity)
            } else {
                FileIcon(url: url, size: fit ? size * 0.7 : size)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard loadsContent else { return }
            if let hit = DuplicateThumbnailCache.shared.cached(url, size: size) {
                image = hit
                return
            }
            image = nil
            let loaded = await DuplicateThumbnailCache.shared.load(url, size: size, scale: displayScale)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
