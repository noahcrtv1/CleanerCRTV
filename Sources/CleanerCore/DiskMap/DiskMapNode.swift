import Foundation

/// Nó da árvore do Mapa do disco: pasta, arquivo grande, grupo de arquivos pequenos ou área sintética.
///
/// Só a raiz guarda um caminho absoluto (em `name`); os demais guardam o nome e o caminho é
/// remontado subindo pelos pais, para a árvore de um disco inteiro caber na memória.
/// Durante a varredura cada pasta é tocada por um único trabalhador; depois, a árvore pertence
/// à main actor (só ela remove, expande e reordena).
public final class DiskMapNode: Identifiable, Hashable, @unchecked Sendable {
    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8
        static let directory = Flags(rawValue: 1 << 0)
        static let package = Flags(rawValue: 1 << 1)
        static let restricted = Flags(rawValue: 1 << 2)
        static let symlink = Flags(rawValue: 1 << 3)
        static let aggregate = Flags(rawValue: 1 << 4)
        static let synthetic = Flags(rawValue: 1 << 5)
        /// Pasta só na nuvem (iCloud/File Provider): não descemos para não baixar nada.
        static let dataless = Flags(rawValue: 1 << 6)
        /// Ponto de montagem descoberto tarde (fstat): sai da árvore na finalização.
        static let foreignMount = Flags(rawValue: 1 << 7)
    }

    /// Nome do item. Na raiz, o caminho absoluto da pasta mapeada.
    public let name: String
    public internal(set) weak var parent: DiskMapNode?
    /// Bytes alocados em disco (descendentes somados, links físicos uma vez só).
    public internal(set) var size: Int64
    /// Soma dos tamanhos lógicos (o "Tamanho" do Finder, sem blocos).
    public internal(set) var logicalSize: Int64
    /// Arquivos contidos: 1 num arquivo, N no grupo de arquivos menores, descendentes numa pasta.
    public internal(set) var fileCount: Int
    /// Do maior para o menor.
    public internal(set) var children: [DiskMapNode] = []
    var flags: Flags

    init(name: String, flags: Flags, size: Int64 = 0, logicalSize: Int64 = 0, fileCount: Int = 0) {
        self.name = name
        self.flags = flags
        self.size = size
        self.logicalSize = logicalSize
        self.fileCount = fileCount
    }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    public static func == (lhs: DiskMapNode, rhs: DiskMapNode) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    // MARK: - Tipo

    public var isDirectory: Bool { flags.contains(.directory) }
    public var isPackage: Bool { flags.contains(.package) }
    /// O macOS não deixou ler (sem permissão ou sem Acesso Total ao Disco).
    public var isRestricted: Bool { flags.contains(.restricted) }
    public var isSymlink: Bool { flags.contains(.symlink) }
    /// Grupo sintético "N arquivos menores" (arquivos abaixo do limite somados).
    public var isAggregate: Bool { flags.contains(.aggregate) }
    /// Área sem caminho real (ex.: "Sistema (somente leitura)").
    public var isSynthetic: Bool { flags.contains(.synthetic) }
    /// Pasta que só existe na nuvem: aparece, mas sem conteúdo local.
    public var isDataless: Bool { flags.contains(.dataless) }
    /// Dá para entrar (pasta de verdade).
    public var isNavigable: Bool { isDirectory && !isSynthetic }

    // MARK: - Nome e caminho

    /// Nome para mostrar. A raiz mostra o último componente; o grupo de arquivos pequenos, a contagem.
    public var displayName: String {
        if isAggregate {
            return fileCount == 1 ? "1 arquivo menor" : "\(fileCount.formatted()) arquivos menores"
        }
        if parent == nil, name.hasPrefix("/") {
            return name == "/" ? "/" : (name as NSString).lastPathComponent
        }
        return name
    }

    /// Caminho físico remontado pelos pais. Grupos e áreas sintéticas devolvem o caminho da pasta-mãe.
    public var path: String {
        if isAggregate || isSynthetic { return parent?.path ?? name }
        var parts: [String] = []
        var node = self
        while let parent = node.parent {
            parts.append(node.name)
            node = parent
        }
        guard !parts.isEmpty else { return node.name }
        let tail = parts.reversed().joined(separator: "/")
        return node.name.hasSuffix("/") ? node.name + tail : node.name + "/" + tail
    }

    /// URL real do item; nil para grupos e áreas sintéticas.
    public var url: URL? {
        guard !isAggregate, !isSynthetic else { return nil }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    // MARK: - Parentesco

    /// Da raiz até este nó (inclusive).
    public var chain: [DiskMapNode] {
        var result: [DiskMapNode] = [self]
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result.reversed()
    }

    public var depth: Int {
        var count = 0
        var node = parent
        while let current = node {
            count += 1
            node = current.parent
        }
        return count
    }

    public func isDescendant(of other: DiskMapNode) -> Bool {
        var node = parent
        while let current = node {
            if current === other { return true }
            node = current.parent
        }
        return false
    }

    /// Pasta (direta) que contém o grupo de arquivos menores, se houver.
    public var aggregateChild: DiskMapNode? { children.first(where: \.isAggregate) }

    public func child(named name: String) -> DiskMapNode? {
        children.first { $0.name == name && !$0.isAggregate && !$0.isSynthetic }
    }

    // MARK: - Ordem e contabilidade

    /// Maior primeiro; empate pelo nome, para a ordem não pular entre varreduras.
    static func ordered(_ lhs: DiskMapNode, before rhs: DiskMapNode) -> Bool {
        lhs.size != rhs.size ? lhs.size > rhs.size : lhs.name < rhs.name
    }

    /// Recoloca um filho cujo tamanho mudou no lugar certo da lista.
    func reposition(_ child: DiskMapNode) {
        guard var index = children.firstIndex(where: { $0 === child }) else { return }
        while index > 0, Self.ordered(children[index], before: children[index - 1]) {
            children.swapAt(index, index - 1)
            index -= 1
        }
        while index + 1 < children.count, Self.ordered(children[index + 1], before: children[index]) {
            children.swapAt(index, index + 1)
            index += 1
        }
    }

    /// Soma (ou subtrai) em `start` e em todos os ancestrais, mantendo cada lista ordenada.
    static func propagate(from start: DiskMapNode?, size: Int64, logical: Int64, files: Int) {
        var node = start
        while let current = node {
            current.size += size
            current.logicalSize += logical
            current.fileCount += files
            current.parent?.reposition(current)
            node = current.parent
        }
    }
}
