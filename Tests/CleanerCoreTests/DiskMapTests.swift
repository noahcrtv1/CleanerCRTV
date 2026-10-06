import Darwin
import Foundation
import Testing
@testable import CleanerCore

/// Pasta temporária com arquivos de tamanho conhecido. Some no fim (até as pastas sem permissão).
private final class DiskMapFixture {
    let root: URL

    init(base: URL = FileManager.default.temporaryDirectory) throws {
        let url = base.appendingPathComponent("diskmap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: DiskMapPaths.resolved(url), isDirectory: true)
    }

    deinit {
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                chmod(root.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    func scan(threshold: Int64 = 1_000_000, excluded: [String] = []) async -> DiskMapTree {
        await DiskMapScanner.scan(root, options: DiskMapScanOptions(smallFileThreshold: threshold, concurrency: 4,
                                                                    excludedPaths: excluded))
    }

    /// Árvore padrão: arquivos grandes e pequenos em três níveis, mais uma pasta vazia.
    func populate() throws {
        try file("big.bin", bytes: 3_000_000)
        try file("small1.txt", bytes: 10_000)
        try file("small2.txt", bytes: 100)
        try file("docs/medium.bin", bytes: 1_500_000)
        try file("docs/note.txt", bytes: 2_000)
        try file("docs/deep/huge.bin", bytes: 4_000_000)
        try folder("empty")
    }
}

private func allocated(_ path: String) -> Int64 { FileSizer.allocatedSize(ofItem: URL(fileURLWithPath: path)) }

/// Cada pasta soma exatamente os filhos e a lista está do maior para o menor.
private func checkInvariants(_ node: DiskMapNode, sourceLocation: SourceLocation = #_sourceLocation) {
    guard node.isDirectory else { return }
    #expect(node.size == node.children.reduce(0) { $0 + $1.size }, "tamanho de \(node.name)", sourceLocation: sourceLocation)
    #expect(node.fileCount == node.children.reduce(0) { $0 + $1.fileCount }, "arquivos de \(node.name)", sourceLocation: sourceLocation)
    for (a, b) in zip(node.children, node.children.dropFirst()) {
        #expect(a.size >= b.size, "ordem em \(node.name)", sourceLocation: sourceLocation)
    }
    for child in node.children {
        #expect(child.parent === node, sourceLocation: sourceLocation)
        checkInvariants(child, sourceLocation: sourceLocation)
    }
}

/// Monta uma árvore à mão (tamanhos de pasta = soma dos filhos).
private func makeNode(_ name: String, size: Int64 = 0, children: [DiskMapNode]? = nil) -> DiskMapNode {
    guard let children else { return DiskMapNode(name: name, flags: [], size: size, logicalSize: size, fileCount: 1) }
    let node = DiskMapNode(name: name, flags: [.directory])
    for child in children { child.parent = node }
    node.children = children.sorted(by: DiskMapNode.ordered)
    node.size = children.reduce(0) { $0 + $1.size }
    node.fileCount = children.reduce(0) { $0 + $1.fileCount }
    return node
}

@Suite("Mapa do disco")
struct DiskMapTests {
    // MARK: - Varredura

    @Test func buildsTreeWithAggregatesAndSortedChildren() async throws {
        let fixture = try DiskMapFixture()
        try fixture.populate()
        let tree = await fixture.scan()
        let root = tree.root

        #expect(!tree.isPartial)
        #expect(tree.restrictedCount == 0)
        checkInvariants(root)

        let files = ["big.bin", "small1.txt", "small2.txt", "docs/medium.bin", "docs/note.txt", "docs/deep/huge.bin"]
        #expect(root.size == files.reduce(0) { $0 + allocated(fixture.path($1)) })
        #expect(root.fileCount == 6)
        #expect(root.logicalSize == 3_000_000 + 10_000 + 100 + 1_500_000 + 2_000 + 4_000_000)

        // Arquivos ≥ 1 MB viram nó; os menores somam no grupo da pasta.
        let names = Set(root.children.filter { !$0.isAggregate }.map(\.name))
        #expect(names == ["big.bin", "docs", "empty"])
        let aggregate = try #require(root.aggregateChild)
        #expect(aggregate.fileCount == 2)
        #expect(aggregate.size == allocated(fixture.path("small1.txt")) + allocated(fixture.path("small2.txt")))
        #expect(aggregate.displayName == "2 arquivos menores")
        #expect(aggregate.url == nil)

        let docs = try #require(root.child(named: "docs"))
        #expect(docs.isDirectory && docs.fileCount == 3)
        #expect(docs.children.first?.name == "deep")
        #expect(docs.aggregateChild?.fileCount == 1)

        let empty = try #require(root.child(named: "empty"))
        #expect(empty.size == 0 && empty.children.isEmpty)

        let huge = try #require(tree.node(atPath: fixture.path("docs/deep/huge.bin")))
        #expect(!huge.isDirectory && huge.fileCount == 1 && huge.logicalSize == 4_000_000)
        #expect(huge.path == fixture.path("docs/deep/huge.bin"))
        #expect(huge.chain.map(\.name).suffix(3) == ["docs", "deep", "huge.bin"])
        #expect(huge.depth == 3)
        #expect(root.path == fixture.root.path)
    }

    @Test func zeroThresholdKeepsEveryFile() async throws {
        let fixture = try DiskMapFixture()
        try fixture.populate()
        let tree = await fixture.scan(threshold: 0)
        checkInvariants(tree.root)
        #expect(tree.root.aggregateChild == nil)
        #expect(tree.root.child(named: "small2.txt") != nil)
        #expect(tree.root.fileCount == 6)
    }

    @Test func hardLinksCountOnce() async throws {
        let fixture = try DiskMapFixture()
        let original = try fixture.file("a/original.bin", bytes: 2_000_000)
        try fixture.folder("b")
        #expect(link(original.path, fixture.path("b/twin.bin")) == 0)
        let tree = await fixture.scan()
        checkInvariants(tree.root)
        #expect(tree.root.size == allocated(original.path))
        #expect(tree.root.fileCount == 1)
    }

    @Test func expandingSmallFilesCountsHardLinksOnce() async throws {
        let fixture = try DiskMapFixture()
        let original = try fixture.file("a/original.txt", bytes: 50_000)
        try fixture.file("a/outro.txt", bytes: 1_000)
        try fixture.file("b/solto.txt", bytes: 1_000)
        #expect(link(original.path, fixture.path("b/gemeo.txt")) == 0)
        let tree = await fixture.scan()
        let (size, files) = (tree.root.size, tree.root.fileCount)
        var listedLinks = 0
        for name in ["a", "b"] {
            let folder = try #require(tree.root.child(named: name))
            let listed = try #require(await DiskMapScanner.listFiles(inDirectoryAt: folder.path, skipping: [], excludedPaths: [],
                                                                    keepLink: tree.linkFilter(for: folder)))
            listedLinks += listed.filter { $0.name == "original.txt" || $0.name == "gemeo.txt" }.count
            tree.replaceAggregate(in: folder, with: listed)
        }
        #expect(listedLinks == 1)
        #expect(tree.root.size == size && tree.root.fileCount == files)
        checkInvariants(tree.root)
    }

    @Test func symlinksAreNotFollowed() async throws {
        let outside = try DiskMapFixture()
        let target = try outside.file("alvo.bin", bytes: 5_000_000)
        let fixture = try DiskMapFixture()
        try fixture.folder("pasta")
        try FileManager.default.createSymbolicLink(atPath: fixture.path("pasta/atalho"), withDestinationPath: target.path)
        try FileManager.default.createSymbolicLink(atPath: fixture.path("link-pasta"), withDestinationPath: outside.root.path)
        let tree = await fixture.scan(threshold: 0)
        checkInvariants(tree.root)
        #expect(tree.root.size < 100_000)
        let link = try #require(tree.node(atPath: fixture.path("pasta/atalho")))
        #expect(link.isSymlink && !link.isDirectory)
        let folderLink = try #require(tree.root.child(named: "link-pasta"))
        #expect(folderLink.isSymlink && folderLink.children.isEmpty)
    }

    @Test func unreadableFolderIsFlaggedRestricted() async throws {
        guard getuid() != 0 else { return }   // root lê tudo
        let fixture = try DiskMapFixture()
        try fixture.file("livre.bin", bytes: 1_200_000)
        try fixture.file("trancada/segredo.bin", bytes: 2_000_000)
        #expect(chmod(fixture.path("trancada"), 0o000) == 0)
        let tree = await fixture.scan()
        let locked = try #require(tree.root.child(named: "trancada"))
        #expect(locked.isRestricted)
        #expect(locked.size == 0 && locked.children.isEmpty)
        #expect(tree.restrictedCount == 1)
        #expect(tree.root.size == allocated(fixture.path("livre.bin")))
        chmod(fixture.path("trancada"), 0o755)
    }

    @Test func excludedFoldersAreSkipped() async throws {
        let fixture = try DiskMapFixture()
        try fixture.populate()
        let tree = await fixture.scan(excluded: [fixture.path("docs") + "/"])
        #expect(tree.root.child(named: "docs") == nil)
        #expect(tree.root.fileCount == 3)
        checkInvariants(tree.root)

        let whole = await fixture.scan(excluded: [fixture.root.path])
        #expect(whole.root.children.isEmpty && whole.root.size == 0)
    }

    @Test func cancelledScanIsPartial() async throws {
        let fixture = try DiskMapFixture()
        try fixture.populate()
        let progress = DiskMapProgress()
        progress.cancel()
        let tree = await DiskMapScanner.scan(fixture.root, progress: progress)
        #expect(tree.isPartial)
    }

    @Test func progressCountsFilesAndBytes() async throws {
        let fixture = try DiskMapFixture()
        try fixture.populate()
        let progress = DiskMapProgress()
        let tree = await DiskMapScanner.scan(fixture.root, options: DiskMapScanOptions(excludedPaths: []), progress: progress)
        let snapshot = progress.snapshot
        #expect(snapshot.files == 6)
        #expect(snapshot.bytes == tree.root.size)
        #expect(snapshot.directories == 4)
    }

    // MARK: - Contabilidade depois de remover

    @Test func removeSubtractsUpTheChain() async throws {
        let fixture = try DiskMapFixture()
        try fixture.populate()
        let tree = await fixture.scan()
        let root = tree.root
        let docs = try #require(root.child(named: "docs"))
        let deep = try #require(docs.child(named: "deep"))
        let huge = try #require(deep.child(named: "huge.bin"))
        let (rootSize, docsSize, rootFiles) = (root.size, docs.size, root.fileCount)

        tree.remove(huge)
        #expect(huge.parent == nil)
        #expect(!tree.contains(huge))
        #expect(deep.size == 0 && deep.fileCount == 0 && deep.children.isEmpty)
        #expect(docs.size == docsSize - huge.size)
        #expect(root.size == rootSize - huge.size)
        #expect(root.fileCount == rootFiles - 1)
        // "docs" encolheu e ficou menor que "big.bin": a ordem acompanha.
        #expect(root.children.first?.name == "big.bin")
        checkInvariants(root)

        tree.remove(docs)
        #expect(root.child(named: "docs") == nil)
        #expect(!tree.contains(deep))
        checkInvariants(root)

        let before = root.size
        tree.remove(root)
        #expect(root.size == before)
    }

    @Test func expandingSmallFilesKeepsTotals() async throws {
        let fixture = try DiskMapFixture()
        try fixture.populate()
        let tree = await fixture.scan()
        let root = tree.root
        let (size, files) = (root.size, root.fileCount)
        let existing = Set(root.children.map(\.name))

        let listed = try #require(await DiskMapScanner.listFiles(inDirectoryAt: root.path, skipping: existing, excludedPaths: []))
        #expect(Set(listed.map(\.name)) == ["small1.txt", "small2.txt"])
        tree.replaceAggregate(in: root, with: listed)

        #expect(root.aggregateChild == nil)
        #expect(root.child(named: "small1.txt")?.parent === root)
        #expect(root.size == size && root.fileCount == files)
        checkInvariants(root)

        #expect(await DiskMapScanner.listFiles(inDirectoryAt: fixture.path("nao-existe"), skipping: [], excludedPaths: []) == nil)
    }

    // MARK: - Caminhos do volume de dados

    @Test(arguments: [
        ("/System/Volumes/Data/Users/ana/Downloads", "/Users/ana/Downloads"),
        ("/System/Volumes/Data/Applications/Foo.app", "/Applications/Foo.app"),
        ("/System/Volumes/Data/private/var/vm", "/private/var/vm"),
        ("/System/Volumes/Data", "/"),
        ("/System/Volumes/Data/", "/"),
        ("/System/Volumes/DataX/arquivo", "/System/Volumes/DataX/arquivo"),
        ("/System/Volumes/Preboot", "/System/Volumes/Preboot"),
        ("/Users/ana", "/Users/ana"),
        ("/Volumes/Backup/Fotos", "/Volumes/Backup/Fotos"),
    ])
    func mapsDataVolumePaths(_ physical: String, _ shown: String) {
        #expect(DiskMapPaths.displayPath(forPhysicalPath: physical) == shown)
    }

    @Test func actionURLRequiresAnExistingItem() throws {
        let fixture = try DiskMapFixture()
        let file = try fixture.file("x.bin", bytes: 10)
        #expect(DiskMapPaths.actionURL(forPhysicalPath: file.path)?.path == file.path)
        #expect(DiskMapPaths.actionURL(forPhysicalPath: fixture.path("sumiu.bin")) == nil)
        #expect(DiskMapPaths.revealURL(forPhysicalPath: fixture.path("sumiu.bin")).path == fixture.path("sumiu.bin"))

        // No Mac de verdade, /System/Volumes/Data/Users/x é o mesmo objeto que /Users/x.
        let home = DiskMapPaths.resolved(Paths.home)
        if DiskMapPaths.isMountPoint(DiskMapPaths.dataVolumePrefix), home.hasPrefix("/Users/") {
            #expect(DiskMapPaths.actionURL(forPhysicalPath: DiskMapPaths.dataVolumePrefix + home)?.path == home)
        }
    }

    // MARK: - Remoção permitida

    @Test func removabilityBlocksSyntheticAndProtectedItems() async throws {
        let fixture = try DiskMapFixture()   // em /private/var/folders: fora das áreas permitidas
        try fixture.populate()
        let tree = await fixture.scan()
        #expect(tree.removability(of: tree.root).reason != nil)
        #expect(tree.removability(of: try #require(tree.root.aggregateChild)).reason != nil)
        #expect(tree.removability(of: try #require(tree.root.child(named: "big.bin"))).reason != nil)

        tree.addSynthetic(name: DiskMapScanner.systemNodeName, size: 1_000_000_000)
        let system = try #require(tree.root.children.first { $0.isSynthetic })
        #expect(system.url == nil)
        #expect(tree.removability(of: system).reason != nil)
        #expect(tree.root.children.first === system)
        checkInvariants(tree.root)
    }

    @Test func removabilityAllowsUserFilesInHome() async throws {
        let fixture = try DiskMapFixture(base: Paths.home.appendingPathComponent(".cleanercrtv-diskmap-tests", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: Paths.home.appendingPathComponent(".cleanercrtv-diskmap-tests")) }
        try fixture.populate()
        let tree = await fixture.scan()
        let big = try #require(tree.root.child(named: "big.bin"))
        #expect(tree.removability(of: big) == .allowed(URL(fileURLWithPath: fixture.path("big.bin"))))
        let docs = try #require(tree.root.child(named: "docs"))
        #expect(tree.removability(of: docs).url?.path == fixture.path("docs"))

        tree.remove(big)
        #expect(tree.removability(of: big).reason != nil)
    }

    @Test func removabilityBlocksUnmeasuredCloudAndPackageContents() async throws {
        guard getuid() != 0 else { return }
        let base = Paths.home.appendingPathComponent(".cleanercrtv-diskmap-tests-pkg", isDirectory: true)
        let fixture = try DiskMapFixture(base: base)
        defer { try? FileManager.default.removeItem(at: base) }
        try fixture.file("Foto.photoslibrary/originals/a.heic", bytes: 1_200_000)
        try fixture.file("trancada/x.bin", bytes: 10)
        try fixture.folder("nuvem")
        #expect(chmod(fixture.path("trancada"), 0o000) == 0)
        defer { chmod(fixture.path("trancada"), 0o755) }
        let tree = await fixture.scan()

        // O pacote inteiro pode sair; as peças de dentro, não.
        let library = try #require(tree.root.child(named: "Foto.photoslibrary"))
        #expect(library.isPackage)
        #expect(tree.removability(of: library).url != nil)
        let inner = try #require(library.child(named: "originals"))
        #expect(tree.removability(of: inner).reason != nil)
        let photo = try #require(tree.node(atPath: fixture.path("Foto.photoslibrary/originals/a.heic")))
        #expect(tree.removability(of: photo).reason != nil)

        let locked = try #require(tree.root.child(named: "trancada"))
        #expect(locked.isRestricted && tree.removability(of: locked).reason != nil)

        let cloud = try #require(tree.root.child(named: "nuvem"))
        #expect(tree.removability(of: cloud).url != nil)
        cloud.flags.insert(.dataless)
        #expect(tree.removability(of: cloud).reason != nil)
    }

    // MARK: - Raios de sol

    @Test func sunburstCoversTheCircleAndNests() async throws {
        let fixture = try DiskMapFixture()
        try fixture.populate()
        let tree = await fixture.scan()
        let layout = DiskMapSunburstLayout(focus: tree.root)

        let ring1 = layout.rings[0].map { layout.arcs[$0] }
        // O grupo de arquivos pequenos (< 0,7°) some; o resto cobre o círculo em proporção ao tamanho.
        let drawn = ring1.reduce(Int64(0)) { $0 + $1.size }
        #expect(abs(ring1.reduce(0) { $0 + $1.sweep } - 360 * Double(drawn) / Double(tree.root.size)) < 1e-6)
        #expect(!ring1.contains { $0.kind == .aggregate })
        #expect(ring1.first?.start == 0)
        for (a, b) in zip(ring1, ring1.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9) }
        #expect(Set(ring1.map(\.branch)).count == ring1.count)

        let docs = try #require(tree.root.child(named: "docs"))
        let docsArc = layout.arcs[try #require(layout.arcIndex(of: docs))]
        let huge = try #require(tree.node(atPath: fixture.path("docs/deep/huge.bin")))
        let hugeArc = layout.arcs[try #require(layout.arcIndex(of: huge))]
        #expect(hugeArc.depth == 3 && hugeArc.kind == .file)
        #expect(hugeArc.isInside(docsArc) && hugeArc.branch == docsArc.branch)

        let middle = (hugeArc.start + hugeArc.end) / 2
        #expect(layout.arcIndex(depth: 3, angle: middle) == layout.arcIndex(of: huge))
        #expect(layout.arcIndex(depth: 7, angle: middle) == nil)

        let window = try #require(DiskMapSunburst.window(of: huge, in: tree.root))
        #expect(window.depth == 3)
        #expect(abs(window.start - hugeArc.start) < 1e-9 && abs(window.end - hugeArc.end) < 1e-9)
        #expect(DiskMapSunburst.window(of: tree.root, in: huge) == nil)
    }

    @Test func sunburstMergesTinySlicesAndLimitsDepth() {
        let tiny = (0..<3).map { makeNode("t\($0)", size: 1) }
        let root = makeNode("/raiz", children: [makeNode("grande", size: 1_000)] + tiny)
        let layout = DiskMapSunburstLayout(focus: root)
        #expect(layout.arcs.count == 2)
        let merged = layout.arcs[1]
        #expect(merged.kind == .merged && merged.node == nil && merged.itemCount == 3 && merged.size == 3)
        #expect(merged.branch == -1)

        // Um item pequeno sozinho some (não vira "outros" de um).
        let lone = DiskMapSunburstLayout(focus: makeNode("/raiz", children: [makeNode("grande", size: 1_000), makeNode("um", size: 1)]))
        #expect(lone.arcs.count == 1)

        var level = makeNode("f", size: 10)
        for depth in 0..<9 { level = makeNode("d\(depth)", children: [level]) }
        let deep = DiskMapSunburstLayout(focus: level, maxDepth: 6)
        #expect(deep.arcs.count == 6)
        #expect(deep.arcs.allSatisfy { $0.sweep == 360 })
        #expect(deep.arcs.map(\.depth) == Array(1...6))

        let empty = DiskMapSunburstLayout(focus: makeNode("/vazia", children: []))
        #expect(empty.arcs.isEmpty)
    }
}
