import Foundation

/// Um setor do gráfico de raios de sol. Ângulos em graus: 0 = topo, sentido horário.
public struct DiskMapArc: Sendable {
    public enum Kind: Sendable, Equatable {
        case directory, file, aggregate, synthetic
        /// Vários itens pequenos demais para aparecer sozinhos, somados num setor só.
        case merged
    }

    /// nil no setor "outros".
    public let node: DiskMapNode?
    /// Pasta que contém o setor.
    public let parent: DiskMapNode
    public let kind: Kind
    /// 1 = primeiro anel em volta do centro.
    public let depth: Int
    public let start: Double
    public let end: Double
    /// Posição do ancestral no primeiro anel (define a cor). -1 = sem ramo (setor "outros" do 1º anel).
    public let branch: Int
    public let size: Int64
    /// Quantos itens o setor "outros" junta (1 nos demais).
    public let itemCount: Int

    public var sweep: Double { end - start }

    /// Fica dentro de `other` (mesmo ramo, anel mais de fora)? A árvore é aninhada, então basta o ângulo.
    public func isInside(_ other: DiskMapArc) -> Bool {
        depth > other.depth && start >= other.start - 1e-9 && end <= other.end + 1e-9
    }
}

/// Gráfico de raios de sol de uma pasta: setores por anel, prontos para desenhar e para achar
/// o setor sob o ponteiro. Calculado uma vez por foco (fora do `body`).
public struct DiskMapSunburstLayout: @unchecked Sendable {
    public static let defaultMaxDepth = 6
    /// Abaixo disso o setor some no desenho: os menores de cada pasta viram "outros".
    public static let defaultMinAngle = 0.7

    public let focus: DiskMapNode
    public let maxDepth: Int
    public let arcs: [DiskMapArc]
    /// Índices de `arcs` por anel (rings[0] = anel 1), em ordem de ângulo.
    public let rings: [[Int]]
    private let indexByNode: [ObjectIdentifier: Int]

    public init(focus: DiskMapNode, maxDepth: Int = defaultMaxDepth, minAngle: Double = defaultMinAngle) {
        self.focus = focus
        self.maxDepth = max(1, maxDepth)
        var arcs: [DiskMapArc] = []
        Self.place(focus, start: 0, span: 360, depth: 1, branch: nil,
                   maxDepth: self.maxDepth, minAngle: minAngle, into: &arcs)
        // Busca em profundidade, da esquerda para a direita: cada anel já sai em ordem de ângulo.
        var rings = Array(repeating: [Int](), count: self.maxDepth)
        var index: [ObjectIdentifier: Int] = [:]
        index.reserveCapacity(arcs.count)
        for (i, arc) in arcs.enumerated() {
            rings[arc.depth - 1].append(i)
            if let node = arc.node { index[ObjectIdentifier(node)] = i }
        }
        self.arcs = arcs
        self.rings = rings
        self.indexByNode = index
    }

    /// Setor no anel `depth` que cobre `angle` (0…360).
    public func arcIndex(depth: Int, angle: Double) -> Int? {
        guard depth >= 1, depth <= rings.count else { return nil }
        let ring = rings[depth - 1]
        var low = 0, high = ring.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let arc = arcs[ring[mid]]
            if angle < arc.start { high = mid - 1 } else if angle >= arc.end { low = mid + 1 } else { return ring[mid] }
        }
        return nil
    }

    public func arcIndex(of node: DiskMapNode) -> Int? { indexByNode[ObjectIdentifier(node)] }

    private static func place(_ directory: DiskMapNode, start: Double, span: Double, depth: Int, branch: Int?,
                              maxDepth: Int, minAngle: Double, into arcs: inout [DiskMapArc]) {
        guard depth <= maxDepth, directory.size > 0, span > 0 else { return }
        let scale = span / Double(directory.size)
        let children = directory.children
        var cursor = start
        var index = 0
        while index < children.count {
            let child = children[index]
            let sweep = Double(child.size) * scale
            if sweep < minAngle {
                // Lista em ordem decrescente: daqui para frente, tudo é pequeno.
                var size: Int64 = 0
                for rest in children[index...] { size += rest.size }
                let count = children.count - index
                let merged = Double(size) * scale
                if count > 1, merged >= minAngle {
                    arcs.append(DiskMapArc(node: nil, parent: directory, kind: .merged, depth: depth,
                                           start: cursor, end: cursor + merged, branch: branch ?? -1,
                                           size: size, itemCount: count))
                }
                return
            }
            let arcBranch = branch ?? index
            arcs.append(DiskMapArc(node: child, parent: directory, kind: kind(of: child), depth: depth,
                                   start: cursor, end: cursor + sweep, branch: arcBranch,
                                   size: child.size, itemCount: 1))
            if child.isNavigable, !child.children.isEmpty {
                place(child, start: cursor, span: sweep, depth: depth + 1, branch: arcBranch,
                      maxDepth: maxDepth, minAngle: minAngle, into: &arcs)
            }
            cursor += sweep
            index += 1
        }
    }

    private static func kind(of node: DiskMapNode) -> DiskMapArc.Kind {
        if node.isAggregate { return .aggregate }
        if node.isSynthetic { return .synthetic }
        return node.isDirectory ? .directory : .file
    }
}

public enum DiskMapSunburst {
    /// Faixa angular de `node` no gráfico centrado em `ancestor`, e o anel em que ele fica
    /// (0 quando é o próprio). Serve para animar o zoom entre os dois. nil se não for descendente.
    public static func window(of node: DiskMapNode, in ancestor: DiskMapNode) -> (start: Double, end: Double, depth: Int)? {
        if node === ancestor { return (0, 360, 0) }
        var chain: [DiskMapNode] = []
        var current: DiskMapNode? = node
        while let item = current, item !== ancestor {
            chain.append(item)
            current = item.parent
        }
        guard current === ancestor else { return nil }
        var start = 0.0, span = 360.0
        for child in chain.reversed() {
            guard let parent = child.parent, parent.size > 0 else { return nil }
            var before: Int64 = 0
            for sibling in parent.children {
                if sibling === child { break }
                before += sibling.size
            }
            start += span * Double(before) / Double(parent.size)
            span *= Double(child.size) / Double(parent.size)
        }
        return (start, start + span, chain.count)
    }
}
