import Foundation
import Testing
@testable import CleanerCore

@Suite("SafetyGuard")
struct SafetyGuardTests {
    let home = "/Users/teste"

    func verdict(_ path: String) -> SafetyGuard.Verdict {
        SafetyGuard.check(canonical: path, home: home)
    }

    @Test(arguments: [
        "/", "/System", "/System/Library/CoreServices", "/usr/bin/ls", "/bin", "/Library", "/Applications",
        "/Users", "/Users/teste", "/Users/teste/Library", "/Users/teste/Documents", "/Users/teste/Desktop",
        "/Users/teste/Library/Caches", "/Users/teste/Library/Application Support", "/Users/teste/Library/Preferences",
        "/Users/teste/Library/Keychains/login.keychain-db", "/Users/teste/.ssh/id_ed25519", "/Volumes/Backup",
        "/private/var/db/foo", "/etc/hosts", "/opt/homebrew", "/Users/teste/.Trash",
        "/Users/outro/Documents/x.txt", "/Library/Caches/com.foo",
    ])
    func blocksProtected(_ path: String) {
        #expect(!verdict(path).isAllowed, "deveria bloquear \(path)")
    }

    @Test(arguments: [
        "/Users/teste/Library/Caches/com.spotify.client",
        "/Users/teste/Library/Logs/DiagnosticReports/x.ips",
        "/Users/teste/Downloads/instalador.dmg",
        "/Users/teste/Library/Developer/Xcode/DerivedData",
        "/Applications/Foo.app",
        "/Volumes/Backup/pasta/arquivo.mov",
        "/Users/teste/.Trash/velho.zip",
        "/Users/Shared/coisa",
    ])
    func allowsUserData(_ path: String) {
        #expect(verdict(path).isAllowed, "deveria permitir \(path)")
    }

    @Test func rejectsDotDot() {
        #expect(!verdict("/Users/teste/Library/Caches/../Preferences").isAllowed)
    }

    @Test func canonicalResolvesParentLinks() throws {
        // /tmp é link para /private/tmp: a pasta-mãe é resolvida.
        let canonical = SafetyGuard.canonicalPath(URL(fileURLWithPath: "/tmp/arquivo-que-nao-existe"))
        #expect(canonical == "/private/tmp/arquivo-que-nao-existe")
    }

    @Test func realCheckBlocksHome() {
        #expect(!SafetyGuard.check(Paths.home).isAllowed)
        #expect(!SafetyGuard.check(Paths.library).isAllowed)
        #expect(!SafetyGuard.check(URL(fileURLWithPath: "/")).isAllowed)
    }
}

@Suite("Remover")
struct RemoverTests {
    /// Histórico descartável: os testes nunca escrevem no histórico real do usuário.
    let history = HistoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json"))

    @Test func dedupesChildrenOfRemovedFolders() {
        let a = RemovalItem(url: URL(fileURLWithPath: "/Users/x/Library/Caches/a"), size: 10)
        let a1 = RemovalItem(url: URL(fileURLWithPath: "/Users/x/Library/Caches/a/b"), size: 5)
        let ab = RemovalItem(url: URL(fileURLWithPath: "/Users/x/Library/Caches/ab"), size: 1)
        let kept = Remover.dedupedByAncestor([a1, ab, a, a])
        #expect(Set(kept.map(\.url.path)) == ["/Users/x/Library/Caches/a", "/Users/x/Library/Caches/ab"])
    }

    @Test func permanentRemovalInsideHomeWorks() async throws {
        let dir = Paths.home.appendingPathComponent(".cleanercrtv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("lixo.bin")
        try Data(repeating: 7, count: 50_000).write(to: file)
        let report = await Remover.remove([RemovalItem(url: file, size: 50_000)], mode: .permanent, source: "Teste", history: history)
        #expect(report.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func blockedPathIsNotRemoved() async {
        let report = await Remover.remove([RemovalItem(url: Paths.library("Preferences"), size: 1)], mode: .permanent, source: "Teste", history: history)
        #expect(report.removed.isEmpty)
        #expect(report.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: Paths.library("Preferences").path))
    }
}

@Suite("Exclusions & FileSizer")
struct MiscTests {
    @Test func exclusionPrefix() {
        #expect(Exclusions.isExcluded(path: "/a/b/c", in: ["/a/b"]))
        #expect(Exclusions.isExcluded(path: "/a/b", in: ["/a/b"]))
        #expect(!Exclusions.isExcluded(path: "/a/bc", in: ["/a/b"]))
    }

    @Test func sizerCountsFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 100_000).write(to: dir.appendingPathComponent("a"))
        try Data(repeating: 1, count: 100_000).write(to: dir.appendingPathComponent("b"))
        // link físico não conta duas vezes
        try FileManager.default.linkItem(at: dir.appendingPathComponent("a"), to: dir.appendingPathComponent("a-link"))
        let size = FileSizer.allocatedSize(of: dir)
        #expect(size >= 200_000 && size < 300_000)
    }
}
