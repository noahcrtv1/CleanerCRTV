import Darwin
import Foundation
import Testing
@testable import CleanerCore

// MARK: - Classificação

@Suite("LargeOld · classificação")
struct LargeOldClassifierTests {
    @Test(arguments: [
        ("mov", LargeOldKind.video), ("MP4", .video), ("mkv", .video), ("braw", .video), ("m4v", .video),
        ("mp3", .audio), ("wav", .audio), ("flac", .audio), ("m4a", .audio),
        ("heic", .image), ("JPG", .image), ("cr2", .image), ("png", .image),
        ("zip", .archive), ("rar", .archive), ("7z", .archive), ("tar", .archive), ("gz", .archive), ("tgz", .archive),
        ("dmg", .diskImage), ("iso", .diskImage), ("pkg", .diskImage), ("xip", .diskImage), ("vmdk", .diskImage),
        ("pdf", .document), ("docx", .document), ("key", .document), ("psd", .document), ("ai", .document),
        ("xlsx", .document), ("pptx", .document), ("txt", .document),
        ("bin", .other), ("xyz123", .other), ("", .other), ("sqlite", .other), ("dylib", .other),
    ])
    func classifiesByExtension(_ pair: (String, LargeOldKind)) {
        #expect(LargeOldClassifier.classify(extension: pair.0) == pair.1, "extensão .\(pair.0)")
    }

    @Test func classifiesURLsAndPackages() {
        #expect(LargeOldClassifier.classify(URL(fileURLWithPath: "/x/Férias.MOV")) == .video)
        #expect(LargeOldClassifier.classify(URL(fileURLWithPath: "/x/sem-extensao")) == .other)
        #expect(LargeOldClassifier.classify(extension: "sparsebundle", isDirectory: true) == .diskImage)
        #expect(LargeOldClassifier.classify(extension: "rtfd", isDirectory: true) == .document)
        #expect(LargeOldClassifier.isInstaller(URL(fileURLWithPath: "/x/Setup.PKG")))
        #expect(!LargeOldClassifier.isInstaller(URL(fileURLWithPath: "/x/Disco.dmg")))
    }

    @Test func pathExtensionIgnoresLeadingDot() {
        #expect(LargeOldRules.pathExtension(of: ".zshrc") == "")
        #expect(LargeOldRules.pathExtension(of: "backup.TAR") == "tar")
        #expect(LargeOldRules.pathExtension(of: "sem-extensao") == "")
        #expect(LargeOldRules.pathExtension(of: "termina-com.") == "")
        #expect(LargeOldRules.pathExtension(of: "Fotos.photoslibrary") == "photoslibrary")
    }
}

// MARK: - Filtros

@Suite("LargeOld · filtros")
struct LargeOldFilterTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400

    func file(_ name: String, mb: Int64, daysAgo: Double, kind: LargeOldKind) -> LargeOldFile {
        LargeOldFile(url: URL(fileURLWithPath: "/Users/teste/\(name)"), size: mb * 1_000_000, kind: kind,
                     lastUsed: now.addingTimeInterval(-daysAgo * day))
    }

    var sample: [LargeOldFile] {
        [
            file("recente.mov", mb: 2_000, daysAgo: 2, kind: .video),
            file("velho.mov", mb: 800, daysAgo: 500, kind: .video),
            file("meio.zip", mb: 120, daysAgo: 200, kind: .archive),
            file("pequeno.pdf", mb: 30, daysAgo: 900, kind: .document),
            file("instalador.dmg", mb: 60, daysAgo: 45, kind: .diskImage),
        ]
    }

    func names(_ files: [LargeOldFile]) -> Set<String> { Set(files.map(\.name)) }

    @Test func sizeThreshold() {
        #expect(names(LargeOldFilter(minSize: LargeOldSizeThreshold.mb10.bytes).apply(to: sample, now: now)).count == 5)
        #expect(names(LargeOldFilter(minSize: LargeOldSizeThreshold.mb50.bytes).apply(to: sample, now: now))
                == ["recente.mov", "velho.mov", "meio.zip", "instalador.dmg"])
        #expect(names(LargeOldFilter(minSize: LargeOldSizeThreshold.mb500.bytes).apply(to: sample, now: now))
                == ["recente.mov", "velho.mov"])
        #expect(names(LargeOldFilter(minSize: LargeOldSizeThreshold.gb1.bytes).apply(to: sample, now: now)) == ["recente.mov"])
    }

    @Test func ageFilter() {
        let base = LargeOldFilter(minSize: LargeOldSizeThreshold.mb10.bytes, age: .any)
        var f = base
        f.age = .month1
        #expect(names(f.apply(to: sample, now: now)) == ["velho.mov", "meio.zip", "pequeno.pdf", "instalador.dmg"])
        f.age = .month6
        #expect(names(f.apply(to: sample, now: now)) == ["velho.mov", "meio.zip", "pequeno.pdf"])
        f.age = .year1
        #expect(names(f.apply(to: sample, now: now)) == ["velho.mov", "pequeno.pdf"])
    }

    @Test func kindFilterAndTotals() {
        let filter = LargeOldFilter(minSize: LargeOldSizeThreshold.mb50.bytes, age: .any, kinds: [.video])
        #expect(names(filter.apply(to: sample, now: now)) == ["recente.mov", "velho.mov"])
        // Totais por tipo ignoram o filtro de tipo, mas respeitam tamanho e idade.
        let totals = filter.totalsByKind(sample, now: now)
        #expect(totals[.video] == LargeOldKindTotal(count: 2, bytes: 2_800_000_000))
        #expect(totals[.archive] == LargeOldKindTotal(count: 1, bytes: 120_000_000))
        #expect(totals[.document] == nil)
    }

    @Test func dashboardCriterion() {
        let found = LargeOldFilter.dashboard.apply(to: sample, now: now)
        #expect(names(found) == ["velho.mov", "meio.zip"])
    }

    @Test func cutoffs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(LargeOldAge.any.cutoff(from: now, calendar: calendar) == nil)
        #expect(LargeOldAge.month1.cutoff(from: now, calendar: calendar) == calendar.date(byAdding: .month, value: -1, to: now))
        #expect(LargeOldAge.month6.cutoff(from: now, calendar: calendar) == calendar.date(byAdding: .month, value: -6, to: now))
        #expect(LargeOldAge.year1.cutoff(from: now, calendar: calendar) == calendar.date(byAdding: .year, value: -1, to: now))
        #expect(LargeOldSizeThreshold.allCases.map(\.title) == ["10 MB", "50 MB", "100 MB", "500 MB", "1 GB"])
        #expect(LargeOldAge.allCases.map(\.title) == ["Qualquer", "+1 mês", "+6 meses", "+1 ano"])
    }
}

// MARK: - Regras de caminho

@Suite("LargeOld · regras")
struct LargeOldRulesTests {
    @Test func pathRules() {
        let home = SafetyGuard.canonicalHome
        let rules = LargeOldRules(options: LargeOldScanOptions(root: Paths.home, exclusions: [home + "/Ignorada"]))
        #expect(!rules.isPathAllowed(home + "/Library"))
        #expect(!rules.isPathAllowed(home + "/Library/Caches"))
        #expect(!rules.isPathAllowed(home + "/Ignorada"))
        #expect(!rules.isPathAllowed(home + "/Ignorada/sub"))
        #expect(!rules.isPathAllowed("/System/Library"))
        #expect(!rules.isPathAllowed("/private/var/folders/x"))
        #expect(!rules.isPathAllowed("/Library/Caches"))
        #expect(rules.isPathAllowed(home + "/Movies"))
        #expect(rules.isPathAllowed(home + "/Ignorada2"))
        #expect(rules.isPathAllowed("/Users"))       // caminho até a pasta pessoal
        #expect(rules.isPathAllowed("/"))
        #expect(rules.isPathAllowed("/Volumes/Externo/Filmes"))
    }

    @Test func datalessPolicyIsRestored() {
        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let inside = LargeOldDataless.withoutMaterializing {
            getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        }
        #expect(inside == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == before)
    }
}

// MARK: - Varredura

/// Árvore descartável dentro da pasta pessoal (o SafetyGuard só libera itens dali).
private struct LargeOldTestTree {
    let root: URL

    init() throws {
        root = Paths.home.appendingPathComponent(".cleanercrtv-largeold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Bytes de verdade (não esparsos), para o tamanho alocado bater.
    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: bytes).write(to: url)
        return url
    }

    func setDates(_ url: URL, modified: Date, accessed: Date) {
        var times = [
            timeval(tv_sec: Int(accessed.timeIntervalSince1970), tv_usec: 0),
            timeval(tv_sec: Int(modified.timeIntervalSince1970), tv_usec: 0),
        ]
        utimes(url.path, &times)
    }

    func options(minSize: Int64, exclusions: [String] = []) -> LargeOldScanOptions {
        // A "pasta pessoal" da varredura é a própria árvore: Library aqui dentro fica de fora.
        LargeOldScanOptions(root: root, minSize: minSize, home: root, exclusions: exclusions,
                            useSpotlight: false, concurrency: 3)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class LargeOldProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [LargeOldProgress] = []
    func append(_ p: LargeOldProgress) { lock.withLock { updates.append(p) } }
    var all: [LargeOldProgress] { lock.withLock { updates } }
}

@Suite("LargeOld · varredura")
struct LargeOldScannerTests {
    let big = 300_000
    let minSize: Int64 = 200_000

    @Test func findsBigFilesAndSkipsTheRest() async throws {
        let tree = try LargeOldTestTree()
        defer { tree.remove() }
        let fm = FileManager.default

        let movie = try tree.file("Filmes/ferias.mov", bytes: big)
        try tree.file("Filmes/pequeno.mov", bytes: 20_000)
        try tree.file("a/b/c/d/instalador.dmg", bytes: big)            // fundo: passa pelas unidades paralelas
        try tree.file("x/y/z/backup.zip", bytes: big)
        try tree.file(".escondido.zip", bytes: big)
        try tree.file(".pasta/grande.zip", bytes: big)
        try tree.file("projeto/node_modules/pacote/grande.bin", bytes: big)
        try tree.file("Foo.app/Contents/Resources/grande.dat", bytes: big)
        try tree.file("Fotos.photoslibrary/originals/IMG_0001.heic", bytes: big)
        try tree.file("Musicas.musiclibrary/Library.musicdb", bytes: big)
        try tree.file("Edicao.fcpbundle/Evento/filme.mov", bytes: big)
        try tree.file("Library/Caches/grande.cache", bytes: big)
        try tree.file("Ignorada/filme.mov", bytes: big)
        // Pacotes de documento entram inteiros (dois arquivos menores que o mínimo somam mais que ele).
        try tree.file("Notas.rtfd/TXT.rtf", bytes: 150_000)
        try tree.file("Notas.rtfd/foto.jpg", bytes: 150_000)
        try tree.file("Disco.sparsebundle/bands/0", bytes: big)
        // Link simbólico não conta; link físico aparece uma vez só.
        try fm.createSymbolicLink(at: tree.root.appendingPathComponent("atalho.mov"), withDestinationURL: movie)
        try fm.linkItem(at: movie, to: tree.root.appendingPathComponent("Filmes/copia-fisica.mov"))
        // Esparso: 2 GB "lógicos", quase nada alocado (como um placeholder do iCloud).
        let sparse = tree.root.appendingPathComponent("vazio.iso")
        fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2_000_000_000)
        try handle.close()

        let log = LargeOldProgressLog()
        let files = await LargeOldScanner.scan(
            tree.options(minSize: minSize, exclusions: [tree.root.appendingPathComponent("Ignorada").path]),
            progress: { log.append($0) }
        )
        let names = Set(files.map(\.name))

        #expect(names.subtracting(["ferias.mov", "copia-fisica.mov"])
                == ["instalador.dmg", "backup.zip", "Notas.rtfd", "Disco.sparsebundle"])
        #expect(names.intersection(["ferias.mov", "copia-fisica.mov"]).count == 1, "link físico deve aparecer uma vez")
        #expect(files.allSatisfy { $0.size >= minSize })
        #expect(files.map(\.size) == files.map(\.size).sorted(by: >), "maiores primeiro")

        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })
        #expect(byName["instalador.dmg"]?.kind == .diskImage)
        #expect(byName["backup.zip"]?.kind == .archive)
        #expect(byName["Notas.rtfd"]?.kind == .document)
        #expect(byName["Notas.rtfd"]?.isPackage == true)
        #expect((byName["Notas.rtfd"]?.size ?? 0) >= 300_000)
        #expect(byName["Disco.sparsebundle"]?.kind == .diskImage)
        #expect(byName["instalador.dmg"]?.folder.hasSuffix("/a/b/c/d") == true)

        let last = try #require(log.all.last)
        #expect(last.found >= files.count)
        #expect(last.filesVisited >= 10)
        #expect(last.foldersVisited >= 5)
    }

    @Test func lastUsedFallsBackToModificationAndAccess() async throws {
        let tree = try LargeOldTestTree()
        defer { tree.remove() }
        let now = Date()
        let old = try tree.file("antigo.mov", bytes: big)
        let modifiedOld = now.addingTimeInterval(-400 * 86_400)
        let accessedOld = now.addingTimeInterval(-300 * 86_400)
        tree.setDates(old, modified: modifiedOld, accessed: accessedOld)
        let ancient = try tree.file("esquecido.zip", bytes: big)
        tree.setDates(ancient, modified: now.addingTimeInterval(-800 * 86_400), accessed: now.addingTimeInterval(-700 * 86_400))
        try tree.file("novo.mov", bytes: big)

        let files = await LargeOldScanner.scan(tree.options(minSize: minSize))
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })
        let antigo = try #require(byName["antigo.mov"])
        #expect(abs(antigo.lastUsed.timeIntervalSince(accessedOld)) < 2, "vale o mais recente entre modificação e acesso")
        #expect(!antigo.lastUsedFromSpotlight)

        var filter = LargeOldFilter(minSize: minSize, age: .month6)
        #expect(Set(filter.apply(to: files, now: now).map(\.name)) == ["antigo.mov", "esquecido.zip"])
        filter.age = .year1
        #expect(Set(filter.apply(to: files, now: now).map(\.name)) == ["esquecido.zip"])
        filter.age = .any
        #expect(filter.apply(to: files, now: now).count == 3)
    }

    @Test func thresholdIsInjectable() async throws {
        let tree = try LargeOldTestTree()
        defer { tree.remove() }
        try tree.file("medio.mov", bytes: 120_000)
        try tree.file("grande.mov", bytes: 600_000)
        let low = await LargeOldScanner.scan(tree.options(minSize: 100_000))
        let high = await LargeOldScanner.scan(tree.options(minSize: 500_000))
        #expect(Set(low.map(\.name)) == ["medio.mov", "grande.mov"])
        #expect(high.map(\.name) == ["grande.mov"])
    }

    @Test func refusesForbiddenRoots() async throws {
        let tree = try LargeOldTestTree()
        defer { tree.remove() }
        try tree.file("Library/grande.mov", bytes: big)
        try tree.file("Ignorada/grande.mov", bytes: big)
        var options = tree.options(minSize: minSize, exclusions: [tree.root.appendingPathComponent("Ignorada").path])

        options.root = tree.root.appendingPathComponent("Library")
        #expect(await LargeOldScanner.scan(options).isEmpty, "a Biblioteca nunca é varrida")
        options.root = tree.root.appendingPathComponent("Ignorada")
        #expect(await LargeOldScanner.scan(options).isEmpty, "pasta ignorada nunca é varrida")
        options.root = URL(fileURLWithPath: "/System/Library")
        #expect(await LargeOldScanner.scan(options).isEmpty)
    }

    @Test func cancelledScanStopsRightAway() async throws {
        let tree = try LargeOldTestTree()
        defer { tree.remove() }
        try tree.file("grande.mov", bytes: big)
        let options = tree.options(minSize: minSize)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LargeOldScanner.scan(options)
        }
        #expect(await task.value.isEmpty)
    }
}
