import Darwin
import Foundation
import Testing
@testable import CleanerCore

/// Pasta descartável para os testes de duplicados (nunca toca arquivos reais).
private struct DuplicateSandbox {
    let url: URL

    init(underHome: Bool = false) throws {
        let base = underHome ? Paths.home : FileManager.default.temporaryDirectory
        let name = (underHome ? ".cleanercrtv-dup-test-" : "dup-test-") + UUID().uuidString
        url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }

    /// Opções para pastas temporárias: o SafetyGuard (com razão) recusa /var/folders, então os testes de
    /// agrupamento o substituem; a integração com o guarda tem teste próprio na pasta pessoal.
    func options(minSize: Int64 = 1, excluded: [String] = []) -> DuplicateScanOptions {
        var options = DuplicateScanOptions(roots: [url], minSize: minSize)
        options.excludedPaths = excluded
        options.isRootAllowed = { _ in true }
        options.isRemovable = { _ in true }
        return options
    }
}

private func randomData(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
    return data
}

private func names(_ group: DuplicateGroup) -> Set<String> { Set(group.files.map(\.name)) }

@Suite("Duplicados — agrupamento")
struct DuplicateScannerTests {
    @Test func groupsOnlyIdenticalContent() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let base = randomData(300_000)
        try box.write("a.bin", base)
        try box.write("sub/b.bin", base)
        try box.write("c.bin", randomData(300_000))                 // mesmo tamanho, outro conteúdo
        var tail = base; tail[tail.count - 1] ^= 0xFF
        try box.write("d.bin", tail)                                // mesmo início, fim diferente
        var middle = base; middle[150_000] ^= 0xFF
        try box.write("e.bin", middle)                              // mesmo início e fim, meio diferente
        let small = randomData(50_000)
        try box.write("p1.dat", small)                              // ≤ 128 KB: comparado inteiro já na 1ª leitura
        try box.write("deep/x/p2.dat", small)

        let result = try #require(await DuplicateScanner.scan(box.options()))
        #expect(result.groups.count == 2)
        let big = try #require(result.groups.first { $0.size == 300_000 })
        #expect(names(big) == ["a.bin", "b.bin"])
        #expect(big.wasted == 300_000)
        let tiny = try #require(result.groups.first { $0.size == 50_000 })
        #expect(names(tiny) == ["p1.dat", "p2.dat"])
        // Os maiores desperdícios vêm primeiro.
        #expect(result.groups.first?.size == 300_000)
    }

    @Test func hardLinksAreNotDuplicates() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let a = try box.write("a.bin", randomData(200_000))
        try FileManager.default.linkItem(at: a, to: box.path("link.bin"))
        let result = try #require(await DuplicateScanner.scan(box.options()))
        #expect(result.groups.isEmpty)

        // Com uma terceira cópia de verdade, o inode entra uma vez só.
        try box.write("copy.bin", try Data(contentsOf: a))
        let again = try #require(await DuplicateScanner.scan(box.options()))
        #expect(again.groups.count == 1)
        #expect(again.groups[0].files.count == 2)
        #expect(names(again.groups[0]).contains("copy.bin"))
    }

    @Test func emptyFilesAreSkipped() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        try box.write("vazio1", Data())
        try box.write("vazio2", Data())
        try box.write("vazio3", Data())
        let result = try #require(await DuplicateScanner.scan(box.options(minSize: 0)))
        #expect(result.groups.isEmpty)
        #expect(result.filesConsidered == 0)
    }

    @Test func respectsMinimumSize() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let data = randomData(50_000)
        try box.write("a", data)
        try box.write("b", data)
        let none = try #require(await DuplicateScanner.scan(box.options(minSize: DuplicateMinSize.kb100.bytes)))
        #expect(none.groups.isEmpty)
        let found = try #require(await DuplicateScanner.scan(box.options(minSize: 10_000)))
        #expect(found.groups.count == 1)
    }

    @Test func skipsHiddenPackagesLibrariesAndLinks() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let data = randomData(150_000)
        try box.write("visivel.bin", data)
        try box.write(".escondido.bin", data)
        try box.write(".pasta/copia.bin", data)
        try box.write("node_modules/pkg/copia.bin", data)
        try box.write("Fotos.photoslibrary/originals/copia.bin", data)
        try box.write("Coisa.app/Contents/copia.bin", data)
        try FileManager.default.createSymbolicLink(at: box.path("atalho.bin"), withDestinationURL: box.path("visivel.bin"))
        let result = try #require(await DuplicateScanner.scan(box.options()))
        #expect(result.groups.isEmpty)
        #expect(result.filesConsidered == 1)
    }

    @Test func respectsExcludedFolders() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let data = randomData(120_000)
        try box.write("a.bin", data)
        try box.write("ignorada/b.bin", data)
        let canonical = DuplicateRoots.canonical(box.path("ignorada"))
        let result = try #require(await DuplicateScanner.scan(box.options(excluded: [canonical])))
        #expect(result.groups.isEmpty)
    }

    @Test func detectsAPFSClones() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let a = try box.write("a.bin", randomData(400_000))
        let b = box.path("b.bin")
        try #require(clonefile(a.path, b.path, 0) == 0, "o volume temporário precisa ser APFS")

        let clones = try #require(await DuplicateScanner.scan(box.options()))
        let group = try #require(clones.groups.first)
        #expect(clones.groups.count == 1)
        #expect(group.isCloneGroup)
        #expect(group.reclaimable == 0)
        #expect(group.wasted == 400_000)
        #expect(group.files.allSatisfy { $0.privateSize == 0 })
        // A seleção automática não marca clones: remover não liberaria nada.
        #expect(DuplicateSelector.autoSelect(clones.groups, rule: .oldest).isEmpty)

        // Uma cópia comum entra no grupo e passa a valer espaço.
        try box.write("c.bin", try Data(contentsOf: a))
        let mixed = try #require(await DuplicateScanner.scan(box.options()))
        let three = try #require(mixed.groups.first)
        #expect(three.files.count == 3)
        #expect(!three.isCloneGroup)
        #expect(three.hasClones)
        #expect(three.storageCount == 2)
        #expect(three.reclaimable == 400_000)
    }

    @Test func safetyGuardFiltersResults() async throws {
        // Em /var/folders (fora das áreas permitidas) nada pode ser oferecido para remoção.
        let temp = try DuplicateSandbox()
        defer { temp.cleanUp() }
        let data = randomData(110_000)
        try temp.write("a", data)
        try temp.write("b", data)
        var guarded = temp.options()
        guarded.isRemovable = { SafetyGuard.check($0).isAllowed }
        let blocked = try #require(await DuplicateScanner.scan(guarded))
        #expect(blocked.groups.isEmpty)

        // Na pasta pessoal, com todas as regras reais, o grupo aparece.
        let home = try DuplicateSandbox(underHome: true)
        defer { home.cleanUp() }
        try home.write("x/um.bin", data)
        try home.write("y/dois.bin", data)
        var real = DuplicateScanOptions(roots: [home.url], minSize: 100_000)
        real.excludedPaths = []
        let found = try #require(await DuplicateScanner.scan(real))
        #expect(found.groups.count == 1)
        #expect(found.groups[0].files.allSatisfy { SafetyGuard.check($0.url).isAllowed })
    }

    @Test func cancelledScanReturnsNil() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        try box.write("a", randomData(200_000))
        let options = box.options()
        let task = Task { () -> DuplicateScanResult? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await DuplicateScanner.scan(options)
        }
        #expect(await task.value == nil)
    }

    @Test func reportsProgress() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let data = randomData(500_000)
        try box.write("a", data)
        try box.write("b", data)
        let progress = DuplicateProgress()
        _ = try #require(await DuplicateScanner.scan(box.options(), progress: progress))
        let snapshot = progress.snapshot
        #expect(snapshot.phase == .finishing)
        #expect(snapshot.candidates == 2)
        #expect(snapshot.hashed == 2)
        #expect(snapshot.bytesHashed == 1_000_000)
    }
}

@Suite("Duplicados — seleção")
struct DuplicateSelectorTests {
    let day: TimeInterval = 86_400

    func file(_ path: String, created: TimeInterval? = nil, modified: TimeInterval? = nil,
              clone: UInt64? = nil, privateSize: Int64? = nil, links: Int = 1) -> DuplicateFile {
        DuplicateFile(url: URL(fileURLWithPath: path), modified: modified.map { Date(timeIntervalSince1970: $0) },
                      created: created.map { Date(timeIntervalSince1970: $0) }, allocatedSize: 1_000,
                      privateSize: privateSize, cloneID: clone, linkCount: links)
    }

    func group(_ files: [DuplicateFile], size: Int64 = 1_000) -> DuplicateGroup {
        DuplicateGroup(id: UUID().uuidString, size: size, files: files)
    }

    @Test func oldestAndNewest() {
        let old = file("/u/Fotos/a.jpg", created: 1 * day, modified: 5 * day)
        let mid = file("/u/Downloads/a.jpg", created: 3 * day, modified: 4 * day)
        let new = file("/u/Desktop/a.jpg", created: 9 * day, modified: 9 * day)
        let g = group([mid, new, old])
        #expect(DuplicateSelector.keeper(of: g.files, rule: .oldest)?.url == old.url)
        #expect(DuplicateSelector.keeper(of: g.files, rule: .newest)?.url == new.url)
        #expect(DuplicateSelector.selectionKeepingOne(g, rule: .oldest) == [mid.url, new.url])
    }

    @Test func preferredFolder() {
        let a = file("/u/Downloads/a.mov", created: 1 * day)
        let b = file("/u/Videos/Projeto/a.mov", created: 5 * day)
        let c = file("/u/Videos/Projeto/sub/a.mov", created: 3 * day)
        let g = group([a, b, c])
        // Dentro da pasta preferida, a mais antiga de lá.
        #expect(DuplicateSelector.keeper(of: g.files, rule: .inFolder(URL(fileURLWithPath: "/u/Videos"))) == c)
        // Nenhuma cópia lá: vale a mais antiga.
        #expect(DuplicateSelector.keeper(of: g.files, rule: .inFolder(URL(fileURLWithPath: "/u/Musica"))) == a)
        // "/u/Video" não é prefixo de pasta de "/u/Videos".
        #expect(DuplicateSelector.keeper(of: g.files, rule: .inFolder(URL(fileURLWithPath: "/u/Video"))) == a)
    }

    @Test func tiesAreDeterministic() {
        let deep = file("/u/a/b/c/x.bin")
        let shallow = file("/u/x.bin")
        let g = group([deep, shallow])
        #expect(DuplicateSelector.keeper(of: g.files, rule: .oldest) == shallow)
        #expect(DuplicateSelector.keeper(of: g.files, rule: .newest) == shallow)
    }

    @Test(arguments: [DuplicateKeepRule.oldest, .newest, .inFolder(URL(fileURLWithPath: "/u/p3"))])
    func autoSelectNeverSelectsEveryCopy(rule: DuplicateKeepRule) {
        var rng = SystemRandomNumberGenerator()
        var groups: [DuplicateGroup] = []
        for g in 0..<300 {
            let count = Int.random(in: 2...6, using: &rng)
            let files = (0..<count).map { i in
                // Datas repetidas e ausentes de propósito, para forçar empates.
                file("/u/p\(Int.random(in: 0...4, using: &rng))/g\(g)/f\(i)",
                     created: Bool.random(using: &rng) ? Double(Int.random(in: 0...3, using: &rng)) * day : nil,
                     modified: Bool.random(using: &rng) ? Double(Int.random(in: 0...3, using: &rng)) * day : nil)
            }
            groups.append(group(files))
        }
        let selection = DuplicateSelector.autoSelect(groups, rule: rule)
        for g in groups {
            let selected = g.files.filter { selection.contains($0.url) }.count
            #expect(selected == g.files.count - 1)
            let keeper = DuplicateSelector.keeper(of: g.files, rule: rule)
            #expect(keeper.map { !selection.contains($0.url) } == true)
        }
    }

    @Test func manualToggleRefusesLastCopy() {
        let a = file("/u/a"), b = file("/u/b"), c = file("/u/c")
        let g = group([a, b, c])
        var selection = Set<URL>()
        var step = DuplicateSelector.toggle(a.url, in: g, selection: selection)
        #expect(!step.refused); selection = step.selection
        step = DuplicateSelector.toggle(b.url, in: g, selection: selection)
        #expect(!step.refused); selection = step.selection
        step = DuplicateSelector.toggle(c.url, in: g, selection: selection)
        #expect(step.refused)
        #expect(step.selection == [a.url, b.url])
        // Desmarcar sempre pode.
        step = DuplicateSelector.toggle(a.url, in: g, selection: selection)
        #expect(!step.refused)
        #expect(step.selection == [b.url])
    }

    @Test func enforcingKeepFreesOneCopy() {
        let a = file("/u/a", created: 1), b = file("/u/b", created: 2)
        let other = group([file("/u/c"), file("/u/d")])
        let g = group([a, b])
        let fixed = DuplicateSelector.enforcingKeep([a.url, b.url, other.files[0].url], in: [g, other])
        #expect(fixed == [b.url, other.files[0].url])
    }

    @Test func freedBytesUnderstandsClonesAndLinks() {
        let a = file("/u/a", clone: 7, privateSize: 0)
        let b = file("/u/b", clone: 7, privateSize: 0)
        let c = file("/u/c", clone: 9, privateSize: 1_000)
        let linked = file("/u/d", clone: 11, privateSize: 1_000, links: 2)
        let g = group([a, b, c, linked])
        #expect(g.storageCount == 3)
        // Tirar um clone de uma família que fica: nada volta.
        #expect(g.freedBytes(removing: [b.url])[b.url] == 0)
        // A família inteira sai: os blocos compartilhados voltam uma vez.
        let both = g.freedBytes(removing: [a.url, b.url])
        #expect(both.values.reduce(0, +) == 1_000)
        #expect(g.freedBytes(removing: [c.url])[c.url] == 1_000)
        #expect(g.freedBytes(removing: [linked.url])[linked.url] == 0)
    }

    @Test func removingFilesDropsSmallGroups() {
        let g = group([file("/u/a"), file("/u/b"), file("/u/c")])
        #expect(g.removing([URL(fileURLWithPath: "/u/a")])?.files.count == 2)
        #expect(g.removing([URL(fileURLWithPath: "/u/a"), URL(fileURLWithPath: "/u/b")]) == nil)
    }

    @Test func removalPlanRechecksDisk() async throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let data = randomData(130_000)
        try box.write("a.bin", data)
        try box.write("b.bin", data)
        try box.write("c.bin", data)
        let result = try #require(await DuplicateScanner.scan(box.options()))
        let g = try #require(result.groups.first)
        let selection = DuplicateSelector.autoSelect(result.groups, rule: .oldest)
        #expect(selection.count == 2)

        let plan = DuplicateSelector.removalPlan(groups: result.groups, selection: selection)
        #expect(plan.items.count == 2)
        #expect(plan.skipped == 0)
        #expect(plan.bytes > 0)

        // Uma cópia marcada mudou depois da varredura: fica de fora.
        let changed = try #require(g.files.first { selection.contains($0.url) })
        try (data + Data([1])).write(to: changed.url)
        let partial = DuplicateSelector.removalPlan(groups: result.groups, selection: selection)
        #expect(partial.items.count == 1)
        #expect(partial.skipped == 1)

        // A cópia que ficaria sumiu: nada do grupo é removido.
        let keeper = try #require(g.files.first { !selection.contains($0.url) })
        try FileManager.default.removeItem(at: keeper.url)
        let none = DuplicateSelector.removalPlan(groups: result.groups, selection: selection)
        #expect(none.items.isEmpty)
        #expect(none.skipped == 2)
    }
}

@Suite("Duplicados — pastas e tipos")
struct DuplicateRootsTests {
    @Test func defaultsAreExistingStandardFolders() {
        for root in DuplicateRoots.defaults {
            #expect(DuplicateRoots.standardFolderNames.contains(root.lastPathComponent))
            #expect(DuplicateRoots.isDirectory(root))
        }
    }

    @Test func persistsRootsAndMinimumSize() throws {
        let suite = "cleanercrtv.dup.tests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }

        #expect(DuplicateRoots.load(from: store) == DuplicateRoots.defaults)
        DuplicateRoots.save([box.url], to: store)
        #expect(DuplicateRoots.load(from: store).map(\.standardizedFileURL.path) == [box.url.standardizedFileURL.path])
        DuplicateRoots.save([], to: store)
        #expect(DuplicateRoots.load(from: store).isEmpty)

        #expect(DuplicateMinSize.load(from: store) == .mb1)
        DuplicateMinSize.mb100.save(to: store)
        #expect(DuplicateMinSize.load(from: store) == .mb100)
    }

    @Test func normalizedDropsNestedAndRepeated() throws {
        let box = try DuplicateSandbox()
        defer { box.cleanUp() }
        let inner = box.path("a/b")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let sibling = box.path("ab")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let result = DuplicateRoots.normalized([inner, box.url, box.url, sibling])
        #expect(result.map(\.path) == [DuplicateRoots.canonical(box.url)])
        let pair = DuplicateRoots.normalized([box.path("a"), sibling])
        #expect(pair.count == 2)
    }

    @Test func rejectsLibrarySystemAndFiles() throws {
        #expect(DuplicateRoots.problem(with: Paths.library) != nil)
        #expect(DuplicateRoots.problem(with: Paths.library("Caches")) != nil)
        #expect(DuplicateRoots.problem(with: URL(fileURLWithPath: "/")) != nil)
        #expect(DuplicateRoots.problem(with: URL(fileURLWithPath: "/System")) != nil)
        #expect(DuplicateRoots.problem(with: URL(fileURLWithPath: "/Applications")) != nil)

        let box = try DuplicateSandbox(underHome: true)
        defer { box.cleanUp() }
        #expect(DuplicateRoots.problem(with: box.url) == nil)
        let file = try box.write("arquivo.txt", Data("oi".utf8))
        #expect(DuplicateRoots.problem(with: file) != nil)
        let library = box.path("Fotos.photoslibrary")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        #expect(DuplicateRoots.problem(with: library) != nil)
    }

    @Test func kinds() {
        #expect(DuplicateKind.of(URL(fileURLWithPath: "/x/foto.JPG")) == .image)
        #expect(DuplicateKind.of(URL(fileURLWithPath: "/x/clipe.mov")) == .video)
        #expect(DuplicateKind.of(URL(fileURLWithPath: "/x/musica.mp3")) == .audio)
        #expect(DuplicateKind.of(URL(fileURLWithPath: "/x/doc.pdf")) == .document)
        #expect(DuplicateKind.of(URL(fileURLWithPath: "/x/pacote.zip")) == .archive)
        #expect(DuplicateKind.of(URL(fileURLWithPath: "/x/semextensao")) == .other)
        #expect(DuplicateKind.hasContentThumbnail(URL(fileURLWithPath: "/x/a.heic")))
        #expect(!DuplicateKind.hasContentThumbnail(URL(fileURLWithPath: "/x/a.zip")))
    }
}
