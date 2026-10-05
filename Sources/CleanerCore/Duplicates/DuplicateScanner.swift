import CryptoKit
import Darwin
import Foundation
import os

/// Opções de uma busca de duplicados.
public struct DuplicateScanOptions: Sendable {
    public var roots: [URL]
    public var minSize: Int64
    /// Lê o id de clone APFS das cópias encontradas (grupos de clones não contam como desperdício).
    public var detectClones: Bool
    /// Pastas ignoradas (Ajustes ▸ Ignorar).
    var excludedPaths: [String]
    /// Ponto de partida aceitável? (Padrão: as regras de `DuplicateRoots.problem`.)
    var isRootAllowed: @Sendable (URL) -> Bool
    /// Só entra nos resultados o que o SafetyGuard deixaria remover.
    var isRemovable: @Sendable (URL) -> Bool

    public init(roots: [URL], minSize: Int64 = DuplicateMinSize.mb1.bytes, detectClones: Bool = true) {
        self.roots = roots
        self.minSize = minSize
        self.detectClones = detectClones
        self.excludedPaths = Exclusions.paths
        self.isRootAllowed = { DuplicateRoots.problem(with: $0) == nil }
        self.isRemovable = { SafetyGuard.check($0).isAllowed }
    }
}

public enum DuplicatePhase: Sendable, Equatable {
    case collecting, comparingEdges, comparingContents, finishing

    public var title: String {
        switch self {
        case .collecting: "Procurando arquivos…"
        case .comparingEdges: "Comparando início e fim…"
        case .comparingContents: "Conferindo o conteúdo byte a byte…"
        case .finishing: "Organizando os resultados…"
        }
    }
}

public struct DuplicateProgressSnapshot: Sendable, Equatable {
    public var phase: DuplicatePhase = .collecting
    /// Arquivos vistos na coleta (de qualquer tamanho).
    public var filesVisited = 0
    /// Arquivos acima do tamanho mínimo.
    public var candidates = 0
    public var hashed = 0
    public var toHash = 0
    public var bytesHashed: Int64 = 0
    public var bytesToHash: Int64 = 0
    public var currentPath: String?

    public init() {}

    /// 0…1 quando a etapa tem total conhecido.
    public var fraction: Double? {
        switch phase {
        case .collecting, .finishing:
            return nil
        case .comparingEdges:
            return toHash > 0 ? min(1, Double(hashed) / Double(toHash)) : nil
        case .comparingContents:
            if bytesToHash > 0 { return min(1, Double(bytesHashed) / Double(bytesToHash)) }
            return toHash > 0 ? min(1, Double(hashed) / Double(toHash)) : nil
        }
    }
}

/// Progresso escrito pelas tarefas da varredura e lido pela interface no ritmo dela.
public final class DuplicateProgress: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: DuplicateProgressSnapshot())

    public init() {}

    public var snapshot: DuplicateProgressSnapshot { state.withLockUnchecked { $0 } }

    func update(_ body: (inout DuplicateProgressSnapshot) -> Void) {
        state.withLockUnchecked { body(&$0) }
    }
}

/// Busca de duplicados em etapas, cada uma descartando o que já não pode ser cópia:
/// tamanho igual → mesmo início e fim (64 KB cada) → mesmo SHA-256 do conteúdo inteiro.
public enum DuplicateScanner {
    static let edgeChunk = 64 * 1024
    static let bufferSize = 1 << 20
    /// Leituras simultâneas: mais que isso só disputa o disco.
    static let ioConcurrency = 4

    /// nil quando cancelada.
    public static func scan(_ options: DuplicateScanOptions,
                            progress: DuplicateProgress = DuplicateProgress()) async -> DuplicateScanResult? {
        let started = Date()
        guard !Task.isCancelled else { return nil }
        progress.update { $0 = DuplicateProgressSnapshot() }

        guard let collection = collect(options, progress: progress, isCancelled: { Task.isCancelled }) else { return nil }
        var skippedCloud = collection.skippedCloud
        var skippedUnreadable = 0

        // 1. Mesmo tamanho.
        let edgeItems = Dictionary(grouping: collection.candidates, by: \.size)
            .values.filter { $0.count > 1 }
            .flatMap { $0 }
            .sorted { $0.path < $1.path }
        let edgeBytes = edgeItems.reduce(Int64(0)) { $0 + min($1.size, Int64(2 * edgeChunk)) }
        progress.update {
            $0.phase = .comparingEdges
            $0.toHash = edgeItems.count
            $0.bytesToHash = edgeBytes
        }

        // 2. Início + fim.
        let edgeOutcomes = await hashAll(edgeItems, full: false, progress: progress)
        if Task.isCancelled { return nil }
        var byEdges: [DuplicateDigestKey: [DuplicateCandidate]] = [:]
        for (item, outcome) in zip(edgeItems, edgeOutcomes) {
            switch outcome {
            case .digest(let digest): byEdges[DuplicateDigestKey(size: item.size, digest: digest), default: []].append(item)
            case .cloud: skippedCloud += 1
            case .unreadable, nil: skippedUnreadable += 1
            }
        }
        var confirmed: [(key: DuplicateDigestKey, items: [DuplicateCandidate])] = []
        var fullItems: [DuplicateCandidate] = []
        for (key, items) in byEdges where items.count > 1 {
            // Até 128 KB, início + fim já é o arquivo inteiro.
            if key.size <= Int64(2 * edgeChunk) {
                confirmed.append((key, items))
            } else {
                fullItems.append(contentsOf: items)
            }
        }

        // 3. Conteúdo inteiro (maiores primeiro: os pequenos preenchem as brechas no fim).
        fullItems.sort { $0.size > $1.size }
        let fullBytes = fullItems.reduce(Int64(0)) { $0 + $1.size }
        progress.update {
            $0.phase = .comparingContents
            $0.hashed = 0
            $0.toHash = fullItems.count
            $0.bytesHashed = 0
            $0.bytesToHash = fullBytes
        }
        let fullOutcomes = await hashAll(fullItems, full: true, progress: progress)
        if Task.isCancelled { return nil }
        var byContent: [DuplicateDigestKey: [DuplicateCandidate]] = [:]
        for (item, outcome) in zip(fullItems, fullOutcomes) {
            switch outcome {
            case .digest(let digest): byContent[DuplicateDigestKey(size: item.size, digest: digest), default: []].append(item)
            case .cloud: skippedCloud += 1
            case .unreadable, nil: skippedUnreadable += 1
            }
        }
        for (key, items) in byContent where items.count > 1 { confirmed.append((key, items)) }

        // 4. Montagem: só o que pode ser removido com segurança.
        progress.update {
            $0.phase = .finishing
            $0.currentPath = nil
        }
        var groups: [DuplicateGroup] = []
        groups.reserveCapacity(confirmed.count)
        for (key, items) in confirmed {
            if Task.isCancelled { return nil }
            if let group = makeGroup(key: key, items: items, options: options) { groups.append(group) }
        }
        groups.sort { a, b in
            if a.reclaimable != b.reclaimable { return a.reclaimable > b.reclaimable }
            if a.wasted != b.wasted { return a.wasted > b.wasted }
            return a.id < b.id
        }
        return DuplicateScanResult(groups: groups, filesConsidered: collection.candidates.count,
                                   skippedCloud: skippedCloud, skippedUnreadable: skippedUnreadable,
                                   duration: Date().timeIntervalSince(started))
    }

    // MARK: - Coleta

    struct Collection {
        var candidates: [DuplicateCandidate] = []
        var skippedCloud = 0
    }

    /// Percorre as pastas com `fts` (sem seguir links, sem trocar de volume) e junta os arquivos comuns
    /// acima do mínimo. Um mesmo inode (links físicos) entra uma vez só.
    static func collect(_ options: DuplicateScanOptions, progress: DuplicateProgress,
                        isCancelled: () -> Bool) -> Collection? {
        DuplicateIOPolicy.withoutMaterializing {
            let home = SafetyGuard.canonicalHome
            let skipPaths = Set([home + "/Library", home + "/.Trash"] + DuplicateRoots.managedFolders(home: home))
            let excluded = options.excludedPaths
            var collection = Collection()
            var seen = Set<DuplicateInodeKey>()
            var visited = 0
            var tick = 0
            var currentDir = ""
            var cancelled = false

            for root in DuplicateRoots.normalized(options.roots) {
                if cancelled || isCancelled() { return nil }
                let rootPath = root.path
                guard options.isRootAllowed(root), !Exclusions.isExcluded(path: rootPath, in: excluded),
                      !skipPaths.contains(where: { rootPath == $0 || rootPath.hasPrefix($0 + "/") })
                else { continue }

                rootPath.withCString { cPath in
                    guard let dup = strdup(cPath) else { return }
                    defer { free(dup) }
                    var paths: [UnsafeMutablePointer<CChar>?] = [dup, nil]
                    guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
                    defer { fts_close(fts) }

                    while let entry = fts_read(fts) {
                        tick += 1
                        if tick & 511 == 0 {
                            if isCancelled() { cancelled = true; return }
                            let snapshot = (visited, collection.candidates.count, currentDir)
                            progress.update {
                                $0.filesVisited = snapshot.0
                                $0.candidates = snapshot.1
                                $0.currentPath = snapshot.2
                            }
                        }
                        switch Int32(entry.pointee.fts_info) {
                        case FTS_D:
                            guard entry.pointee.fts_level > 0 else { continue }
                            let path = String(cString: entry.pointee.fts_path)
                            let flags = entry.pointee.fts_statp?.pointee.st_flags ?? 0
                            if flags & UInt32(SF_DATALESS) != 0 {
                                // Pasta do iCloud ainda não baixada: listar já dispararia download.
                                collection.skippedCloud += 1
                                fts_set(fts, entry, FTS_SKIP)
                            } else if shouldSkipDirectory(path: path, flags: flags, skipPaths: skipPaths, excluded: excluded) {
                                fts_set(fts, entry, FTS_SKIP)
                            } else {
                                currentDir = path
                            }
                        case FTS_F:
                            guard let st = entry.pointee.fts_statp?.pointee else { continue }
                            visited += 1
                            let size = Int64(st.st_size)
                            guard size > 0, size >= options.minSize, st.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                            let path = String(cString: entry.pointee.fts_path)
                            if lastComponent(path).hasPrefix(".") { continue }
                            if st.st_flags & UInt32(SF_DATALESS) != 0 {
                                collection.skippedCloud += 1
                                continue
                            }
                            if !excluded.isEmpty, Exclusions.isExcluded(path: path, in: excluded) { continue }
                            guard seen.insert(DuplicateInodeKey(device: st.st_dev, inode: st.st_ino)).inserted else { continue }
                            collection.candidates.append(DuplicateCandidate(
                                path: path, size: size, device: st.st_dev, inode: st.st_ino,
                                linkCount: Int(st.st_nlink), allocated: Int64(st.st_blocks) * 512,
                                modified: date(st.st_mtimespec), created: date(st.st_birthtimespec)))
                        default:
                            // Links simbólicos, pastas ilegíveis, ciclos: nada a fazer.
                            continue
                        }
                    }
                }
            }
            if cancelled { return nil }
            let total = (visited, collection.candidates.count)
            progress.update {
                $0.filesVisited = total.0
                $0.candidates = total.1
            }
            return collection
        }
    }

    static func shouldSkipDirectory(path: String, flags: UInt32, skipPaths: Set<String>, excluded: [String]) -> Bool {
        let name = lastComponent(path)
        if name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 { return true }
        if name == "node_modules" { return true }
        if skipPaths.contains(path) { return true }
        if !excluded.isEmpty, Exclusions.isExcluded(path: path, in: excluded) { return true }
        // Pacotes (apps, bibliotecas de Fotos/Música, projetos) são opacos: nunca abertos nem comparados.
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = name[name.index(after: dot)...].lowercased()
            if DuplicateRoots.opaqueExtensions.contains(ext) { return true }
            let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
            if values?.isPackage == true { return true }
        }
        return false
    }

    // MARK: - Leitura e hash

    enum HashOutcome: Sendable {
        case digest(SHA256.Digest)
        /// Placeholder do iCloud: não foi lido.
        case cloud
        case unreadable
    }

    /// Até `ioConcurrency` arquivos de cada vez. nil na posição = cancelado antes de ler.
    static func hashAll(_ items: [DuplicateCandidate], full: Bool, progress: DuplicateProgress) async -> [HashOutcome?] {
        guard !items.isEmpty else { return [] }
        var results = [HashOutcome?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, HashOutcome?).self) { group in
            var next = 0
            while next < min(ioConcurrency, items.count) {
                let index = next
                group.addTask { (index, hashOne(items[index], full: full, progress: progress)) }
                next += 1
            }
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                if next < items.count, !Task.isCancelled {
                    let index = next
                    group.addTask { (index, hashOne(items[index], full: full, progress: progress)) }
                    next += 1
                }
            }
        }
        return results
    }

    static func hashOne(_ item: DuplicateCandidate, full: Bool, progress: DuplicateProgress) -> HashOutcome? {
        if Task.isCancelled { return nil }
        let outcome = DuplicateIOPolicy.withoutMaterializing {
            digest(of: item, full: full, isCancelled: { Task.isCancelled }) { bytes in
                progress.update { $0.bytesHashed += Int64(bytes) }
            }
        }
        progress.update {
            $0.hashed += 1
            $0.currentPath = item.path
        }
        return Task.isCancelled ? nil : outcome
    }

    /// SHA-256 do início + fim (`full == false`) ou do conteúdo inteiro, em blocos de 1 MB.
    /// O arquivo é conferido de novo ao abrir (mesmo inode, mesmo tamanho, não é placeholder do iCloud).
    static func digest(of item: DuplicateCandidate, full: Bool, isCancelled: () -> Bool,
                       onBytes: (Int) -> Void) -> HashOutcome {
        let fd = open(item.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_dev == item.device, st.st_ino == item.inode, Int64(st.st_size) == item.size
        else { return .unreadable }
        if st.st_flags & UInt32(SF_DATALESS) != 0 { return .cloud }

        let small = item.size <= Int64(2 * edgeChunk)
        // Leitura única de arquivos grandes: não vale encher o cache do sistema com eles.
        if full { _ = fcntl(fd, F_NOCACHE, 1) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: full ? bufferSize : edgeChunk, alignment: 16)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        let status: DuplicateReadStatus
        if full || small {
            status = feed(&hasher, fd: fd, offset: 0, length: item.size, buffer: buffer, isCancelled: isCancelled, onBytes: onBytes)
        } else {
            let head = feed(&hasher, fd: fd, offset: 0, length: Int64(edgeChunk), buffer: buffer,
                            isCancelled: isCancelled, onBytes: onBytes)
            status = head != .ok ? head : feed(&hasher, fd: fd, offset: item.size - Int64(edgeChunk), length: Int64(edgeChunk),
                                               buffer: buffer, isCancelled: isCancelled, onBytes: onBytes)
        }
        switch status {
        case .ok: return .digest(hasher.finalize())
        case .cloud: return .cloud
        case .failed, .cancelled: return .unreadable
        }
    }

    static func feed(_ hasher: inout SHA256, fd: Int32, offset start: Int64, length: Int64,
                     buffer: UnsafeMutableRawBufferPointer, isCancelled: () -> Bool,
                     onBytes: (Int) -> Void) -> DuplicateReadStatus {
        var offset = start
        var remaining = length
        while remaining > 0 {
            if isCancelled() { return .cancelled }
            let wanted = Int(min(Int64(buffer.count), remaining))
            let count = pread(fd, buffer.baseAddress, wanted, off_t(offset))
            if count < 0 {
                if errno == EINTR { continue }
                // Com a materialização desligada, ler um placeholder do iCloud dá EDEADLK em vez de baixar.
                return errno == EDEADLK ? .cloud : .failed
            }
            if count == 0 { return .failed }   // o arquivo encolheu no meio da leitura
            autoreleasepool {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            }
            offset += Int64(count)
            remaining -= Int64(count)
            onBytes(count)
        }
        return .ok
    }

    // MARK: - Montagem

    static func makeGroup(key: DuplicateDigestKey, items: [DuplicateCandidate], options: DuplicateScanOptions) -> DuplicateGroup? {
        let files: [DuplicateFile] = items.compactMap { item in
            let url = URL(fileURLWithPath: item.path, isDirectory: false)
            guard options.isRemovable(url) else { return nil }
            let clone = options.detectClones ? DuplicateCloneInfo.read(path: item.path) : DuplicateCloneInfo()
            return DuplicateFile(url: url, modified: item.modified, created: item.created,
                                 allocatedSize: item.allocated, privateSize: clone.privateSize, cloneID: clone.cloneID,
                                 linkCount: item.linkCount, device: item.device, inode: item.inode)
        }
        guard files.count > 1 else { return nil }
        let hex = key.digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return DuplicateGroup(id: "\(key.size)-\(hex)", size: key.size, files: DuplicateSelector.sortedByOrigin(files))
    }

    // MARK: - Utilidades

    static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }

    static func lastComponent(_ path: String) -> Substring {
        guard let slash = path.lastIndex(of: "/") else { return Substring(path) }
        return path[path.index(after: slash)...]
    }
}

// MARK: - Tipos internos

struct DuplicateCandidate: Sendable {
    let path: String
    let size: Int64
    let device: Int32
    let inode: UInt64
    let linkCount: Int
    let allocated: Int64
    let modified: Date
    let created: Date
}

struct DuplicateInodeKey: Hashable {
    let device: Int32
    let inode: UInt64
}

struct DuplicateDigestKey: Hashable, Sendable {
    let size: Int64
    let digest: SHA256.Digest
}

enum DuplicateReadStatus: Equatable {
    case ok, cloud, failed, cancelled
}

/// Política de E/S da thread atual: ler um arquivo "sem dados" do iCloud falha em vez de baixá-lo.
enum DuplicateIOPolicy {
    static func withoutMaterializing<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }
        return try body()
    }
}
