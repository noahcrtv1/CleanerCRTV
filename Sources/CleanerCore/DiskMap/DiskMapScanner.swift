import Darwin
import Foundation

public struct DiskMapScanOptions: Sendable {
    /// Arquivos menores que isto não viram nó: somam no grupo "N arquivos menores" da pasta.
    public var smallFileThreshold: Int64
    /// Trabalhadores lendo pastas em paralelo.
    public var concurrency: Int
    /// Pastas ignoradas (Ajustes ▸ Ignorar).
    public var excludedPaths: [String]

    public init(smallFileThreshold: Int64 = 1_000_000,
                concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                excludedPaths: [String] = Exclusions.paths) {
        self.smallFileThreshold = smallFileThreshold
        self.concurrency = max(1, concurrency)
        self.excludedPaths = excludedPaths
    }
}

/// Contadores da varredura em andamento. Os trabalhadores escrevem; a interface lê ~10×/s.
public final class DiskMapProgress: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var files = 0
        public var directories = 0
        public var bytes: Int64 = 0
        /// Última pasta lida (caminho físico).
        public var currentPath = ""
        public init() {}
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var cancelled = false

    public init() {}

    public var snapshot: Snapshot { lock.withLock { state } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }

    func record(files: Int, bytes: Int64, directory: String) {
        lock.withLock {
            state.files += files
            state.bytes += bytes
            state.directories += 1
            state.currentPath = directory
        }
    }
}

public enum DiskMapScanner {
    /// Pastas da raiz do volume de dados que só o sistema lê (índice do Spotlight, eventos,
    /// versões). Ficam fora da árvore; o espaço delas entra em "Sistema (somente leitura)".
    static let dataRootSkips: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
        ".PKInstallSandboxManager-SystemSoftware", ".MobileBackups",
    ]

    public static let systemNodeName = "Sistema (somente leitura)"

    /// Varre uma pasta ou volume. Não sai do volume, não segue links, não baixa nada da nuvem.
    public static func scan(_ url: URL, kind: DiskMapTree.Kind = .folder, title: String? = nil,
                            options: DiskMapScanOptions = DiskMapScanOptions(),
                            progress: DiskMapProgress = DiskMapProgress()) async -> DiskMapTree {
        let path = DiskMapPaths.resolved(url)
        let name = title ?? FileManager.default.displayName(atPath: path)
        return await runOffMainThread(progress: progress) {
            scanSync(rootPath: path, kind: kind, title: name, options: options, progress: progress, rootSkips: [])
        }
    }

    /// "Disco de inicialização": varre o volume de dados (onde ficam /Users, /Applications…) e
    /// soma o resto do espaço usado num nó "Sistema (somente leitura)".
    public static func scanStartupDisk(options: DiskMapScanOptions = DiskMapScanOptions(),
                                       progress: DiskMapProgress = DiskMapProgress()) async -> DiskMapTree {
        let usage = VolumeUsage.startup()
        let dataPath = DiskMapPaths.dataVolumePrefix
        let hasDataVolume = DiskMapPaths.isMountPoint(dataPath)
        var options = options
        if hasDataVolume {
            // As exclusões são guardadas pelo caminho de sempre (/Users/x/…).
            options.excludedPaths += options.excludedPaths.filter { $0.hasPrefix("/") }.map { dataPath + $0 }
        }
        let tree = await runOffMainThread(progress: progress) { [options] in
            scanSync(rootPath: hasDataVolume ? dataPath : "/", kind: .startupDisk, title: usage.name,
                     options: options, progress: progress, rootSkips: hasDataVolume ? dataRootSkips : [])
        }
        // Volume do sistema, volumes auxiliares, instantâneos e o que não deu para ler.
        let allocated = usage.total - usage.free
        let rest = allocated - tree.root.size
        if !tree.isPartial, rest > 0 {
            tree.addSynthetic(name: systemNodeName, size: rest)
        }
        return tree
    }

    /// Lista os arquivos de uma pasta (para abrir o grupo "N arquivos menores"). nil = sem acesso.
    /// `keepLink` decide se um link físico entra (ele só conta na pasta onde a varredura o somou).
    public static func listFiles(inDirectoryAt path: String, skipping names: Set<String>,
                                 excludedPaths: [String] = Exclusions.paths,
                                 keepLink: @escaping @Sendable (UInt64) -> Bool = { _ in true }) async -> [DiskMapNode]? {
        let excluded = Set(excludedPaths + excludedPaths.filter { $0.hasPrefix("/") }.map { DiskMapPaths.dataVolumePrefix + $0 })
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: DiskMapDirectoryReader.listFiles(atPath: path, skipping: names, excluded: excluded,
                                                                                  keepLink: keepLink))
            }
        }
    }

    // MARK: - Interno

    /// Os trabalhadores bloqueiam em chamadas de disco: rodam em threads do GCD, fora do pool
    /// cooperativo do Swift, para não travar as outras tarefas do app.
    private static func runOffMainThread(progress: DiskMapProgress,
                                         _ work: @escaping @Sendable () -> DiskMapTree) async -> DiskMapTree {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: work())
                }
            }
        } onCancel: {
            progress.cancel()
        }
    }

    static func scanSync(rootPath: String, kind: DiskMapTree.Kind, title: String, options: DiskMapScanOptions,
                         progress: DiskMapProgress, rootSkips: Set<String>) -> DiskMapTree {
        let start = Date()
        let root = DiskMapNode(name: rootPath, flags: [.directory])
        var info = stat()
        var restricted = 0
        var owners: [UInt64: ObjectIdentifier] = [:]
        if lstat(rootPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
            let walker = DiskMapWalker(root: root, rootPath: rootPath, device: info.st_dev, options: options,
                                       progress: progress, rootSkips: rootSkips)
            walker.run(concurrency: options.concurrency)
            restricted = walker.restrictedCount
            owners = walker.hardLinkOwners
        } else {
            root.flags.insert(.restricted)
            restricted = 1
        }
        finalize(root)
        return DiskMapTree(root: root, kind: kind, title: title, isPartial: progress.isCancelled,
                           smallFileThreshold: options.smallFileThreshold,
                           duration: Date().timeIntervalSince(start), restrictedCount: restricted,
                           hardLinkOwners: owners)
    }

    /// Fecha as contas de baixo para cima: cria os grupos de arquivos menores, soma e ordena.
    /// Durante a varredura, `size`/`fileCount` de cada pasta guardam só os arquivos pequenos diretos.
    static func finalize(_ root: DiskMapNode) {
        var order: [DiskMapNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            order.append(node)
            for child in node.children where child.isDirectory { stack.append(child) }
        }
        for node in order.reversed() {
            if node.children.contains(where: { $0.flags.contains(.foreignMount) }) {
                node.children.removeAll { $0.flags.contains(.foreignMount) }
            }
            if node.fileCount > 0 {
                let aggregate = DiskMapNode(name: "", flags: [.aggregate], size: node.size,
                                            logicalSize: node.logicalSize, fileCount: node.fileCount)
                aggregate.parent = node
                node.children.append(aggregate)
            }
            var size: Int64 = 0, logical: Int64 = 0, files = 0
            for child in node.children {
                size += child.size
                logical += child.logicalSize
                files += child.fileCount
            }
            node.size = size
            node.logicalSize = logical
            node.fileCount = files
            node.children.sort(by: DiskMapNode.ordered)
        }
    }
}

/// Varredura paralela: uma pilha de pastas compartilhada; cada trabalhador pega uma, lê tudo
/// com `getattrlistbulk` e devolve as subpastas para a pilha. Cada pasta é lida por um só
/// trabalhador, então os filhos de um nó nunca são escritos por duas threads.
final class DiskMapWalker: @unchecked Sendable {
    private struct Job {
        let node: DiskMapNode
        let path: String
    }

    private let root: DiskMapNode
    private let device: dev_t
    private let threshold: Int64
    private let progress: DiskMapProgress
    private let rootSkips: Set<String>
    private let excluded: Set<String>
    private let excludedParents: Set<String>

    private let condition = NSCondition()
    private var stack: [Job]
    private var active = 0

    private let linkLock = NSLock()
    /// Link físico → pasta onde ele foi contado (a única que o mostra ao abrir os arquivos menores).
    private var linkOwners: [UInt64: ObjectIdentifier] = [:]
    private var restricted = 0

    init(root: DiskMapNode, rootPath: String, device: dev_t, options: DiskMapScanOptions,
         progress: DiskMapProgress, rootSkips: Set<String>) {
        self.root = root
        self.device = device
        self.threshold = max(0, options.smallFileThreshold)
        self.progress = progress
        self.rootSkips = rootSkips
        let paths = options.excludedPaths.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        excluded = Set(paths)
        excludedParents = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        stack = [Job(node: root, path: rootPath)]
        if Exclusions.isExcluded(path: rootPath, in: paths) { stack = [] }
    }

    var restrictedCount: Int { linkLock.withLock { restricted } }
    var hardLinkOwners: [UInt64: ObjectIdentifier] { linkLock.withLock { linkOwners } }

    func run(concurrency: Int) {
        DispatchQueue.concurrentPerform(iterations: concurrency) { _ in worker() }
    }

    private func worker() {
        // Nunca materializar arquivos e pastas que estão só na nuvem.
        let policyType = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)
        let previous = getiopolicy_np(policyType, IOPOL_SCOPE_THREAD)
        setiopolicy_np(policyType, IOPOL_SCOPE_THREAD, Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF))
        defer { if previous >= 0 { setiopolicy_np(policyType, IOPOL_SCOPE_THREAD, previous) } }

        let capacity = DiskMapDirectoryReader.bufferSize
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }

        var finished: [Job]?
        while let job = nextJob(completing: finished) {
            finished = process(job, buffer: buffer, capacity: capacity)
        }
    }

    /// Entrega a próxima pasta (ou nil quando acabou ou foi cancelado) e devolve à pilha as
    /// subpastas da anterior.
    private func nextJob(completing subdirectories: [Job]?) -> Job? {
        condition.lock()
        defer { condition.unlock() }
        if let subdirectories {
            active -= 1
            if !subdirectories.isEmpty {
                stack.append(contentsOf: subdirectories)
                condition.broadcast()
            }
        }
        while true {
            if progress.isCancelled {
                stack.removeAll()
                condition.broadcast()
                return nil
            }
            if let job = stack.popLast() {
                active += 1
                return job
            }
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    private func markRestricted(_ node: DiskMapNode) {
        node.flags.insert(.restricted)
        linkLock.withLock { restricted += 1 }
    }

    /// Link físico: só a primeira ocorrência conta (e fica registrada na pasta dela).
    private func firstSighting(of fileID: UInt64, in directory: DiskMapNode) -> Bool {
        linkLock.withLock {
            guard linkOwners[fileID] == nil else { return false }
            linkOwners[fileID] = ObjectIdentifier(directory)
            return true
        }
    }

    private func process(_ job: Job, buffer: UnsafeMutableRawPointer, capacity: Int) -> [Job] {
        let node = job.node
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == EACCES || code == EPERM { markRestricted(node) }
            progress.record(files: 0, bytes: 0, directory: job.path)
            return []
        }
        defer { close(fd) }

        var info = stat()
        if fstat(fd, &info) == 0, info.st_dev != device {
            node.flags.insert(.foreignMount)
            return []
        }

        let isRoot = node === root
        let checkExcluded = !excluded.isEmpty && excludedParents.contains(job.path)
        let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
        var subdirectories: [Job] = []
        var files = 0
        var bytes: Int64 = 0

        let result = DiskMapDirectoryReader.forEachEntry(fd: fd, buffer: buffer, capacity: capacity) { entry in
            guard entry.error == 0, let rawName = entry.name else { return }
            if entry.isDirectory {
                // Outro volume, autofs ou ponto de montagem: fora (como FTS_XDEV).
                if entry.mountStatus & (DiskMapDirectoryReader.mountPoint | DiskMapDirectoryReader.mountTrigger) != 0 { return }
                if entry.device != 0, entry.device != device { return }
                let name = String(cString: rawName)
                if isRoot, rootSkips.contains(name) { return }
                let childPath = prefix + name
                if checkExcluded, excluded.contains(childPath) { return }
                var flags: DiskMapNode.Flags = [.directory]
                if DiskMapPackages.isPackage(name) { flags.insert(.package) }
                if entry.flags & DiskMapDirectoryReader.datalessFlag != 0 { flags.insert(.dataless) }
                let child = DiskMapNode(name: name, flags: flags)
                child.parent = node
                node.children.append(child)
                if !flags.contains(.dataless) { subdirectories.append(Job(node: child, path: childPath)) }
                return
            }
            if checkExcluded, excluded.contains(prefix + String(cString: rawName)) { return }
            if entry.isRegularFile, entry.linkCount > 1, !firstSighting(of: entry.fileID, in: node) { return }
            let size = max(0, entry.allocatedSize)
            let logical = max(0, entry.logicalSize)
            files += 1
            bytes += size
            if size >= threshold {
                var flags: DiskMapNode.Flags = []
                if entry.isSymlink { flags.insert(.symlink) }
                let child = DiskMapNode(name: String(cString: rawName), flags: flags, size: size,
                                        logicalSize: logical, fileCount: 1)
                child.parent = node
                node.children.append(child)
            } else {
                // Até a finalização, pastas acumulam aqui só os arquivos pequenos diretos.
                node.size += size
                node.logicalSize += logical
                node.fileCount += 1
            }
        }
        if result == EACCES || result == EPERM { markRestricted(node) }
        progress.record(files: files, bytes: bytes, directory: job.path)
        return subdirectories
    }
}
