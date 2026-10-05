import Foundation
import UniformTypeIdentifiers

/// Categoria de um arquivo grande (filtros e coluna "Tipo").
public enum LargeOldKind: String, CaseIterable, Sendable, Hashable, Identifiable, Codable {
    case video, audio, image, archive, diskImage, document, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .video: "Vídeos"
        case .audio: "Áudio"
        case .image: "Imagens"
        case .archive: "Compactados"
        case .diskImage: "Imagens de disco e instaladores"
        case .document: "Documentos"
        case .other: "Outros"
        }
    }

    /// Nome no singular, para uma linha da tabela.
    public var singularTitle: String {
        switch self {
        case .video: "Vídeo"
        case .audio: "Áudio"
        case .image: "Imagem"
        case .archive: "Compactado"
        case .diskImage: "Imagem de disco"
        case .document: "Documento"
        case .other: "Outro"
        }
    }
}

/// Classificação por extensão + UTType. As listas explícitas vêm antes porque o UTType erra
/// para o que interessa aqui (PSD "é" imagem, PKG "é" compactado, .bin "é" MacBinary…).
public enum LargeOldClassifier {
    static let installerExtensions: Set<String> = [
        "pkg", "mpkg", "xip", "msi", "exe", "apk", "ipa", "appimage", "deb", "rpm",
    ]

    static let diskImageExtensions: Set<String> = [
        "dmg", "iso", "img", "cdr", "toast", "sparseimage", "sparsebundle", "udif",
        "vhd", "vhdx", "vmdk", "vdi", "qcow2", "hdd", "hds",
    ]

    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "key", "numbers",
        "odt", "ods", "odp", "rtf", "rtfd", "epub", "txt", "md", "csv",
        "psd", "psb", "ai", "eps", "indd", "idml", "sketch", "fig", "xd",
        "afdesign", "afphoto", "afpub", "prproj", "aep", "drp", "blend", "c4d",
    ]

    static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst",
        "lz4", "lzma", "lz", "z", "cab", "jar", "war", "sit", "sitx", "cpgz", "arj",
    ]

    static let videoExtensions: Set<String> = [
        "mkv", "braw", "r3d", "vob", "m2ts", "mts", "flv", "wmv", "rmvb", "ogv",
    ]

    static let audioExtensions: Set<String> = ["flac", "ape", "dsf", "dff", "opus", "wv"]

    /// O UTType chama de "compactado", mas na prática é qualquer binário.
    static let otherExtensions: Set<String> = ["bin", "dat"]

    /// `isPackage`: pasta que o Finder mostra como arquivo (.pages, .sparsebundle) usa o UTType de pasta.
    public static func classify(_ url: URL, isPackage: Bool = false) -> LargeOldKind {
        classify(extension: url.pathExtension, isDirectory: isPackage)
    }

    public static func classify(extension rawExtension: String, isDirectory: Bool = false) -> LargeOldKind {
        let ext = rawExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if installerExtensions.contains(ext) || diskImageExtensions.contains(ext) { return .diskImage }
        if documentExtensions.contains(ext) { return .document }
        if archiveExtensions.contains(ext) { return .archive }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if otherExtensions.contains(ext) { return .other }

        let type = isDirectory
            ? UTType(filenameExtension: ext, conformingTo: .directory)
            : UTType(filenameExtension: ext)
        guard let type, !type.isDynamic else { return .other }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .compositeContent) {
            return .document
        }
        return .other
    }

    /// Instaladores (.pkg, .xip…) entram em "Imagens de disco e instaladores", mas a linha diz "Instalador".
    public static func isInstaller(_ url: URL) -> Bool {
        installerExtensions.contains(url.pathExtension.lowercased())
    }
}
