import Foundation
import UniformTypeIdentifiers

/// Uma cópia dentro de um grupo de duplicados.
public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let modified: Date?
    public let created: Date?
    /// Blocos ocupados no disco (como "Tamanho no disco" do Finder).
    public let allocatedSize: Int64
    /// Bytes que só este arquivo ocupa (APFS). Clone puro = 0. nil = o volume não informa.
    public let privateSize: Int64?
    /// Identificador de clone APFS: mesmo id = mesmos blocos no disco. nil = o volume não informa.
    public let cloneID: UInt64?
    /// Quantos caminhos apontam para estes dados (links físicos). Acima de 1, remover este caminho não libera nada.
    public let linkCount: Int
    let device: Int32
    let inode: UInt64

    init(url: URL, modified: Date?, created: Date?, allocatedSize: Int64, privateSize: Int64? = nil,
         cloneID: UInt64? = nil, linkCount: Int = 1, device: Int32 = 0, inode: UInt64 = 0) {
        self.url = url
        self.modified = modified
        self.created = created
        self.allocatedSize = allocatedSize
        self.privateSize = privateSize
        self.cloneID = cloneID
        self.linkCount = linkCount
        self.device = device
        self.inode = inode
    }

    public var folder: URL { url.deletingLastPathComponent() }
    public var name: String { url.lastPathComponent }

    /// Data de "nascimento" do conteúdo: a mais antiga entre criação e modificação
    /// (cópias costumam ganhar data de criação nova, mas mantêm a de modificação).
    public var originDate: Date? {
        switch (created, modified) {
        case let (c?, m?): min(c, m)
        case let (c?, nil): c
        case let (nil, m?): m
        default: nil
        }
    }
}

/// Arquivos idênticos byte a byte.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    public let id: String
    /// Tamanho lógico de cada cópia.
    public let size: Int64
    /// O "original" provável primeiro (mais antigo; empate: caminho mais raso).
    public let files: [DuplicateFile]
    public let kind: DuplicateKind
    /// Quantos "conteúdos" ocupam disco de verdade: clones APFS do mesmo dado contam uma vez.
    public let storageCount: Int

    init(id: String, size: Int64, files: [DuplicateFile]) {
        self.id = id
        self.size = size
        self.files = files
        // Cópias podem ter extensões diferentes ("foto" e "foto.jpg"): vale a primeira que diz o tipo.
        self.kind = files.lazy.map { DuplicateKind.of($0.url) }.first { $0 != .other } ?? .other
        var clones = Set<UInt64>()
        var count = 0
        for file in files {
            if let id = file.cloneID {
                if clones.insert(id).inserted { count += 1 }
            } else {
                count += 1
            }
        }
        self.storageCount = count
    }

    public var displayName: String { files.first?.name ?? "" }

    /// Cópia usada para miniatura e pré-visualização (a primeira com extensão que o Quick Look entende).
    public var previewFile: DuplicateFile? {
        files.first { DuplicateKind.hasContentThumbnail($0.url) } ?? files.first
    }

    /// Espaço das cópias extras, sem considerar clones: tamanho × (cópias − 1).
    public var wasted: Int64 { size * Int64(max(0, files.count - 1)) }

    /// O que dá para recuperar de fato deixando uma cópia (exclui o que é clone APFS).
    public var reclaimable: Int64 { size * Int64(max(0, storageCount - 1)) }

    /// Todas as cópias são o mesmo dado no disco: remover não libera espaço.
    public var isCloneGroup: Bool { files.count >= 2 && storageCount == 1 }

    /// Alguma cópia divide os blocos com outra deste grupo.
    public var hasClones: Bool { storageCount < files.count }

    /// Esta cópia divide blocos com outra cópia do grupo?
    public func isClone(_ file: DuplicateFile) -> Bool {
        guard let id = file.cloneID else { return false }
        return files.contains { $0.url != file.url && $0.cloneID == id }
    }

    /// Grupo sem os arquivos dados; nil quando sobra menos de 2.
    public func removing(_ urls: Set<URL>) -> DuplicateGroup? {
        let remaining = files.filter { !urls.contains($0.url) }
        guard remaining.count >= 2 else { return nil }
        return remaining.count == files.count ? self : DuplicateGroup(id: id, size: size, files: remaining)
    }

    /// Bytes que voltam ao disco por arquivo, se `selected` sair e o resto ficar.
    /// Clones só liberam a parte própria, a menos que a família inteira saia; links físicos não liberam nada.
    public func freedBytes(removing selected: Set<URL>) -> [URL: Int64] {
        var result: [URL: Int64] = [:]
        var families: [UInt64: [DuplicateFile]] = [:]
        for file in files where file.cloneID != nil { families[file.cloneID!, default: []].append(file) }

        for file in files where selected.contains(file.url) {
            if file.linkCount > 1 { result[file.url] = 0; continue }
            // privateSize = blocos só deste arquivo (num arquivo comum, igual ao alocado).
            let own = file.privateSize ?? file.allocatedSize
            guard let id = file.cloneID, let family = families[id], family.count > 1 else {
                result[file.url] = own
                continue
            }
            let goingAway = family.filter { selected.contains($0.url) }
            if goingAway.count == family.count, goingAway.first?.url == file.url {
                // A família toda sai: os blocos compartilhados voltam uma vez.
                result[file.url] = max(own, family.map(\.allocatedSize).max() ?? own)
            } else {
                result[file.url] = own
            }
        }
        return result
    }
}

/// Categoria do arquivo (para ícone, filtro e miniatura).
public enum DuplicateKind: String, CaseIterable, Sendable, Hashable {
    case image, video, audio, document, archive, other

    public var title: String {
        switch self {
        case .image: "Imagens"
        case .video: "Vídeos"
        case .audio: "Áudio"
        case .document: "Documentos"
        case .archive: "Compactados"
        case .other: "Outros"
        }
    }

    public var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .other: "doc"
        }
    }

    public static func of(_ url: URL) -> DuplicateKind {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }

    /// Tem miniatura de conteúdo que vale gerar (imagem, vídeo, PDF).
    public static func hasContentThumbnail(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .pdf)
    }
}

/// Tamanho mínimo considerado na busca.
public enum DuplicateMinSize: Int64, CaseIterable, Sendable, Identifiable {
    case kb100 = 100_000
    case mb1 = 1_000_000
    case mb10 = 10_000_000
    case mb100 = 100_000_000

    public static let defaultsKey = "duplicates.minSize"

    public var id: Int64 { rawValue }
    public var bytes: Int64 { rawValue }

    public var label: String {
        switch self {
        case .kb100: "100 KB"
        case .mb1: "1 MB"
        case .mb10: "10 MB"
        case .mb100: "100 MB"
        }
    }

    public static func load(from store: UserDefaults = .standard) -> DuplicateMinSize {
        DuplicateMinSize(rawValue: Int64(store.integer(forKey: defaultsKey))) ?? .mb1
    }

    public func save(to store: UserDefaults = .standard) {
        store.set(Int(rawValue), forKey: Self.defaultsKey)
    }
}

/// Resultado de uma varredura completa.
public struct DuplicateScanResult: Sendable {
    public var groups: [DuplicateGroup]
    /// Arquivos acima do tamanho mínimo considerados.
    public var filesConsidered: Int
    /// Itens do iCloud que não estão baixados (nunca lidos, para não disparar download).
    public var skippedCloud: Int
    /// Arquivos que não deu para ler ou que mudaram durante a varredura.
    public var skippedUnreadable: Int
    /// Pastas que o macOS não deixou listar (sem permissão).
    public var unreadableFolders: Int = 0
    /// Pastas da busca que existiam e foram percorridas (0 = nenhuma disponível).
    public var rootsScanned: Int = 0
    public var duration: TimeInterval
}
