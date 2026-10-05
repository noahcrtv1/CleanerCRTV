import Foundation

/// Resultado de uma varredura do Mapa do disco.
public final class DiskMapTree: @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        case startupDisk, home, volume, folder
    }

    public let root: DiskMapNode
    public let kind: Kind
    /// Nome mostrado para a raiz ("Macintosh HD", "Pasta pessoal", nome da pasta).
    public let title: String
    /// A varredura foi interrompida: tamanhos parciais.
    public let isPartial: Bool
    /// Arquivos abaixo deste tamanho viram o grupo "N arquivos menores" de cada pasta.
    public let smallFileThreshold: Int64
    public let duration: TimeInterval
    /// Pastas que o macOS não deixou ler.
    public let restrictedCount: Int
    public let date = Date()

    init(root: DiskMapNode, kind: Kind, title: String, isPartial: Bool,
         smallFileThreshold: Int64, duration: TimeInterval, restrictedCount: Int) {
        self.root = root
        self.kind = kind
        self.title = title
        self.isPartial = isPartial
        self.smallFileThreshold = smallFileThreshold
        self.duration = duration
        self.restrictedCount = restrictedCount
    }

    /// Caminho físico da raiz (no disco de inicialização, /System/Volumes/Data).
    public var rootPath: String { root.name }

    /// O nó ainda faz parte desta árvore (não foi removido)?
    public func contains(_ node: DiskMapNode) -> Bool {
        node === root || node.isDescendant(of: root)
    }

    /// Procura pelo caminho físico (ou pelo caminho mostrado, sem /System/Volumes/Data).
    public func node(atPath path: String) -> DiskMapNode? {
        let candidates = [path, DiskMapPaths.dataVolumePrefix + path]
        for candidate in candidates {
            let base = rootPath
            if candidate == base { return root }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            guard candidate.hasPrefix(prefix) else { continue }
            var node = root
            var found = true
            for component in candidate.dropFirst(prefix.count).split(separator: "/") {
                guard let next = node.child(named: String(component)) else { found = false; break }
                node = next
            }
            if found { return node }
        }
        return nil
    }

    // MARK: - Mudanças depois da varredura (main actor)

    /// Tira o nó da árvore e desconta tamanho e arquivos de todos os ancestrais.
    /// Não toca no disco: é só a contabilidade depois que o `Remover` agiu.
    public func remove(_ node: DiskMapNode) {
        guard node !== root, let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        node.parent = nil
        DiskMapNode.propagate(from: parent, size: -node.size, logical: -node.logicalSize, files: -node.fileCount)
    }

    /// Troca o grupo "N arquivos menores" da pasta pela lista real (lida sob demanda).
    public func replaceAggregate(in directory: DiskMapNode, with files: [DiskMapNode]) {
        guard directory.isNavigable, contains(directory) else { return }
        let aggregates = directory.children.filter(\.isAggregate)
        directory.children.removeAll { $0.isAggregate }
        var size: Int64 = 0, logical: Int64 = 0, count = 0
        for old in aggregates {
            old.parent = nil
            size -= old.size
            logical -= old.logicalSize
            count -= old.fileCount
        }
        let existing = Set(directory.children.map(\.name))
        for file in files where !existing.contains(file.name) {
            file.parent = directory
            directory.children.append(file)
            size += file.size
            logical += file.logicalSize
            count += file.fileCount
        }
        directory.children.sort(by: DiskMapNode.ordered)
        // O próprio diretório já está com os filhos certos; só os totais sobem.
        DiskMapNode.propagate(from: directory, size: size, logical: logical, files: count)
    }

    /// Área sem caminho (ex.: o volume do sistema), pendurada na raiz.
    func addSynthetic(name: String, size: Int64) {
        let node = DiskMapNode(name: name, flags: [.synthetic], size: size, logicalSize: size, fileCount: 0)
        node.parent = root
        root.children.append(node)
        root.children.sort(by: DiskMapNode.ordered)
        root.size += size
        root.logicalSize += size
    }
}
