import CoreServices
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Andamento da varredura (enviado no máximo ~10 vezes por segundo).
public struct LargeOldProgress: Sendable, Equatable {
    public var filesVisited = 0
    public var foldersVisited = 0
    public var found = 0
    public var bytesFound: Int64 = 0
    /// Última pasta em que algum dos leitores entrou.
    public var currentFolder = ""

    public init() {}
}

public struct LargeOldScanOptions: Sendable {
    public var root: URL
    /// Só entra o que ocupar pelo menos isto em disco.
    public var minSize: Int64
    /// Pasta pessoal cuja Biblioteca fica de fora (injetável nos testes).
    public var home: URL
    /// Pastas ignoradas (Ajustes ▸ Ignorar).
    public var exclusions: [String]
    /// Busca "Aberto em" no Spotlight; sem isso, usa modificação/acesso.
    public var useSpotlight: Bool
    /// Leitores em paralelo.
    public var concurrency: Int

    public init(
        root: URL = Paths.home,
        minSize: Int64 = LargeOldSizeThreshold.default.bytes,
        home: URL = Paths.home,
        exclusions: [String] = Exclusions.paths,
        useSpotlight: Bool = true,
        concurrency: Int = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
    ) {
        self.root = root
        self.minSize = minSize
        self.home = home
        self.exclusions = exclusions
        self.useSpotlight = useSpotlight
        self.concurrency = max(1, concurrency)
    }
}

/// Procura arquivos grandes sem ler o conteúdo de nada.
///
/// - `fts` físico, sem atravessar volumes; ~/Library, ocultos, `node_modules`, bibliotecas de mídia e
///   pastas ignoradas ficam de fora; apps e bundles de código nem aparecem.
/// - Pacotes de documento (.pages, .sparsebundle…) entram inteiros, sem listar o que há dentro.
/// - Tamanho = blocos alocados: placeholders do iCloud contam ~0 e nunca são baixados.
/// - As duas primeiras camadas de pastas viram unidades de trabalho lidas em paralelo.
public enum LargeOldScanner {
    /// Bibliotecas de apps de mídia: nunca listadas, nunca abertas.
    static let libraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary",
        "imovielibrary", "fcpbundle", "logicx", "band", "tvlibrary", "lrlibrary", "lrdata",
        "cocatalog", "cocatalogdb",
    ]

    /// Pastas que nunca valem a pena (dependências regeneráveis, backups e lixeiras de outros sistemas).
    static let skippedFolderNames: Set<String> = [
        "node_modules", "Backups.backupdb", "$RECYCLE.BIN", "System Volume Information",
    ]

    /// Camada a partir da qual as pastas viram unidades paralelas.
    static let splitLevel = 2

    /// Varre `options.root`. Cancelada, devolve lista vazia (resultado parcial engana: faltariam pastas).
    public static func scan(
        _ options: LargeOldScanOptions,
        progress: (@Sendable (LargeOldProgress) -> Void)? = nil
    ) async -> [LargeOldFile] {
        let context = LargeOldScanContext(options: options, progress: progress)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Leitura de disco bloqueante: fora do pool cooperativo do Swift.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: context.run())
                }
            }
        } onCancel: {
            context.cancel()
        }
    }

    /// Por que esta pasta não pode ser a raiz da varredura (nil = pode).
    /// Vale a pasta pessoal (menos a Biblioteca), /Users/Shared e discos externos graváveis.
    public static func rootProblem(_ url: URL, home: URL = Paths.home, exclusions: [String] = Exclusions.paths) -> String? {
        rootProblem(rules: LargeOldRules(options: LargeOldScanOptions(root: url, home: home, exclusions: exclusions)), url: url)
    }

    static func rootProblem(rules: LargeOldRules, url: URL) -> String? {
        guard let path = rules.rootPath else { return "A pasta não existe mais." }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return "Escolha uma pasta, não um arquivo." }
        let home = SafetyGuard.canonicalHome
        let inArea = path == home || path.hasPrefix(home + "/") || path == "/Users/Shared"
            || path.hasPrefix("/Users/Shared/") || path.hasPrefix("/Volumes/")
        guard inArea else { return "Escolha a pasta pessoal, uma pasta dentro dela ou um disco externo." }
        if path == rules.homeLibrary || path.hasPrefix(rules.homeLibrary + "/") {
            return "A Biblioteca fica de fora: caches e dados de apps são assunto do Lixo do sistema."
        }
        if Exclusions.isExcluded(path: path, in: rules.exclusions) {
            return "Essa pasta está na lista de pastas ignoradas (Ajustes ▸ Ignorar)."
        }
        guard rules.isPathAllowed(path) else { return "Essa pasta é protegida e não pode ser analisada." }
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "Esse disco é somente leitura: nada nele pode ser removido."
        }
        return nil
    }

    /// Discos montados que valem como raiz (externos e partições graváveis; sem o disco de inicialização).
    /// Pode demorar em volumes de rede: chame fora da main.
    public static func scannableVolumes() -> [LargeOldVolume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey,
                                      .volumeIsLocalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"), SafetyGuard.realpathString(url.path) != "/",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true, values.volumeIsReadOnly != true,
                  values.volumeIsBrowsable != false else { return nil }
            return LargeOldVolume(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent,
                                  isNetwork: values.volumeIsLocal == false)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct LargeOldVolume: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isNetwork: Bool

    public init(url: URL, name: String, isNetwork: Bool = false) {
        self.url = url
        self.name = name
        self.isNetwork = isNetwork
    }
}

// MARK: - Regras de caminho

struct LargeOldRules: Sendable {
    let rootPath: String?
    let homeLibrary: String
    let exclusions: [String]
    let protectedPrefixes: [String]
    let allowedRoots: [String]
    let ownPaths: [String]

    init(options: LargeOldScanOptions) {
        rootPath = SafetyGuard.realpathString(options.root.path)
        let home = SafetyGuard.realpathString(options.home.path) ?? options.home.standardizedFileURL.path
        homeLibrary = home + "/Library"
        // Exclusões gravadas sem resolver links (ex.: /tmp) também valem pelo caminho real.
        exclusions = Array(Set(options.exclusions + options.exclusions.compactMap(SafetyGuard.realpathString)))
        let realHome = SafetyGuard.canonicalHome
        protectedPrefixes = SafetyGuard.protectedPrefixes(home: realHome)
        allowedRoots = [realHome, "/Users/Shared", "/Applications", "/Volumes"]
        ownPaths = SafetyGuard.ownPaths()
    }

    /// Regras que dependem só do caminho (valem também para a raiz escolhida).
    func isPathAllowed(_ path: String) -> Bool {
        if path == homeLibrary || path.hasPrefix(homeLibrary + "/") { return false }
        if Exclusions.isExcluded(path: path, in: exclusions) { return false }
        for prefix in protectedPrefixes where path == prefix || path.hasPrefix(prefix + "/") { return false }
        if ownPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        let asAncestor = path == "/" ? "/" : path + "/"
        return allowedRoots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(asAncestor) }
    }

    static func isHidden(name: Substring, flags: UInt32) -> Bool {
        name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
    }

    /// Extensão em minúsculas ("" quando não há, ou quando o nome só começa com ponto).
    static func pathExtension(of name: Substring) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? "" : ext.lowercased()
    }
}

// MARK: - Estado compartilhado

final class LargeOldScanContext: @unchecked Sendable {
    let options: LargeOldScanOptions
    let rules: LargeOldRules
    private(set) var rootDevice: dev_t = 0

    private let progressHandler: (@Sendable (LargeOldProgress) -> Void)?
    private let lock = NSLock()
    private var cancelled = false
    private var progress = LargeOldProgress()
    private var lastEmit: UInt64 = 0
    private var units: [String] = []
    private var nextUnit = 0
    private var results: [LargeOldFile] = []
    private var hardLinks: [URL: LargeOldHardLinkKey] = [:]

    init(options: LargeOldScanOptions, progress: (@Sendable (LargeOldProgress) -> Void)?) {
        self.options = options
        self.rules = LargeOldRules(options: options)
        self.progressHandler = progress
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    /// Varredura completa, síncrona (chamada fora do pool cooperativo).
    func run() -> [LargeOldFile] {
        defer { report(LargeOldWorkerDelta(), force: true) }
        guard !isCancelled, let rootPath = rules.rootPath,
              LargeOldScanner.rootProblem(rules: rules, url: options.root) == nil else { return [] }
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { return [] }
        rootDevice = st.st_dev

        // Camadas de cima numa passada só; o resto vira unidades paralelas.
        let planner = LargeOldWorker(context: self)
        var planned: [String] = []
        LargeOldDataless.withoutMaterializing {
            planner.walk(rootPath, splitLevel: LargeOldScanner.splitLevel, units: &planned)
        }
        planner.finish()
        lock.withLock { units = planned }

        let workers = min(options.concurrency, planned.count)
        if workers > 0, !isCancelled {
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                let worker = LargeOldWorker(context: self)
                var ignored: [String] = []
                LargeOldDataless.withoutMaterializing {
                    while let unit = takeUnit() {
                        worker.walk(unit, splitLevel: nil, units: &ignored)
                        if worker.stopped { break }
                    }
                }
                worker.finish()
            }
        }
        return lock.withLock { cancelled ? [] : Self.deduplicated(results, hardLinks: hardLinks) }
    }

    private func takeUnit() -> String? {
        lock.withLock {
            guard !cancelled, nextUnit < units.count else { return nil }
            defer { nextUnit += 1 }
            return units[nextUnit]
        }
    }

    func collect(_ files: [LargeOldFile], hardLinks links: [URL: LargeOldHardLinkKey]) {
        lock.withLock {
            results.append(contentsOf: files)
            hardLinks.merge(links) { first, _ in first }
        }
    }

    /// Soma o que um leitor andou e avisa a interface se já passou o intervalo.
    func report(_ delta: LargeOldWorkerDelta, force: Bool = false) {
        let snapshot: LargeOldProgress? = lock.withLock {
            progress.filesVisited += delta.files
            progress.foldersVisited += delta.folders
            progress.found += delta.found
            progress.bytesFound += delta.bytes
            if let folder = delta.folder { progress.currentFolder = folder }
            let now = DispatchTime.now().uptimeNanoseconds
            guard force || now &- lastEmit >= 100_000_000 else { return nil }
            lastEmit = now
            return progress
        }
        if let snapshot { progressHandler?(snapshot) }
    }

    /// Links físicos do mesmo arquivo aparecem uma vez só; maiores primeiro.
    static func deduplicated(_ files: [LargeOldFile], hardLinks: [URL: LargeOldHardLinkKey]) -> [LargeOldFile] {
        var seen = Set<LargeOldHardLinkKey>()
        let unique = files
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.url.path < $1.url.path }
            .filter { file in
                guard let key = hardLinks[file.url] else { return true }
                return seen.insert(key).inserted
            }
        return unique
    }
}

struct LargeOldHardLinkKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

struct LargeOldWorkerDelta {
    var files = 0
    var folders = 0
    var found = 0
    var bytes: Int64 = 0
    var folder: String?
}

// MARK: - Leitor

/// Um leitor por thread: contadores locais, enviados em lotes ao contexto.
final class LargeOldWorker {
    private let context: LargeOldScanContext
    private let rules: LargeOldRules
    private let minSize: Int64
    private let useSpotlight: Bool
    private var delta = LargeOldWorkerDelta()
    private var pending = 0
    private var results: [LargeOldFile] = []
    private var hardLinks: [URL: LargeOldHardLinkKey] = [:]
    private var packageCache: [String: LargeOldPackageKind] = [:]
    private var kindCache: [String: LargeOldKind] = [:]
    private(set) var stopped = false

    init(context: LargeOldScanContext) {
        self.context = context
        self.rules = context.rules
        self.minSize = context.options.minSize
        self.useSpotlight = context.options.useSpotlight
    }

    func walk(_ path: String, splitLevel: Int?, units: inout [String]) {
        guard !stopped, let dup = strdup(path) else { return }
        defer { free(dup) }
        var argv: [UnsafeMutablePointer<CChar>?] = [dup, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }

        while let entry = fts_read(fts) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                delta.folders += 1
                pending += 1
                if entry.pointee.fts_level == 0 {
                    delta.folder = path
                    break
                }
                guard let st = entry.pointee.fts_statp?.pointee else {
                    _ = fts_set(fts, entry, FTS_SKIP)
                    break
                }
                let dirPath = String(cString: entry.pointee.fts_path)
                switch decision(forDirectory: dirPath, flags: st.st_flags) {
                case .skip:
                    _ = fts_set(fts, entry, FTS_SKIP)
                case .package:
                    _ = fts_set(fts, entry, FTS_SKIP)
                    considerPackage(dirPath, st: st)
                case .descend:
                    if st.st_dev != context.rootDevice {
                        _ = fts_set(fts, entry, FTS_SKIP)
                    } else if let splitLevel, Int(entry.pointee.fts_level) >= splitLevel {
                        units.append(dirPath)
                        _ = fts_set(fts, entry, FTS_SKIP)
                    } else {
                        delta.folder = dirPath
                    }
                }
            case FTS_F:
                delta.files += 1
                pending += 1
                if let st = entry.pointee.fts_statp?.pointee {
                    let allocated = Int64(st.st_blocks) * 512
                    if allocated >= minSize { considerFile(String(cString: entry.pointee.fts_path), st: st, allocated: allocated) }
                }
            default:
                break
            }
            if pending >= 512 {
                flush()
                if context.isCancelled { stopped = true; return }
            }
        }
    }

    /// Envia o que sobrou e entrega os achados ao contexto.
    func finish() {
        flush()
        context.collect(results, hardLinks: hardLinks)
        results.removeAll()
        hardLinks.removeAll()
    }

    private func flush() {
        guard pending > 0 || delta.found > 0 else { return }
        context.report(delta)
        delta = LargeOldWorkerDelta()
        pending = 0
    }

    // MARK: Decisões

    private enum DirectoryDecision { case descend, skip, package }

    private func decision(forDirectory path: String, flags: UInt32) -> DirectoryDecision {
        let name = Self.name(of: path)
        if LargeOldRules.isHidden(name: name, flags: flags) { return .skip }
        if LargeOldScanner.skippedFolderNames.contains(String(name)) { return .skip }
        guard rules.isPathAllowed(path) else { return .skip }
        let ext = LargeOldRules.pathExtension(of: name)
        guard !ext.isEmpty else { return .descend }
        if LargeOldScanner.libraryExtensions.contains(ext) { return .skip }
        switch packageKind(ext) {
        case .code: return .skip
        case .document: return .package
        case .none: return .descend
        }
    }

    private func packageKind(_ ext: String) -> LargeOldPackageKind {
        if let cached = packageCache[ext] { return cached }
        let kind: LargeOldPackageKind
        if let type = UTType(filenameExtension: ext, conformingTo: .directory), !type.isDynamic {
            if type.conforms(to: .bundle) || type.conforms(to: .application) || type.conforms(to: .framework) {
                kind = .code
            } else if type.conforms(to: .package) {
                kind = .document
            } else {
                kind = .none
            }
        } else {
            kind = .none
        }
        packageCache[ext] = kind
        return kind
    }

    private func kind(forExtension ext: String, isDirectory: Bool) -> LargeOldKind {
        let key = isDirectory ? ext + "/" : ext
        if let cached = kindCache[key] { return cached }
        let kind = LargeOldClassifier.classify(extension: ext, isDirectory: isDirectory)
        kindCache[key] = kind
        return kind
    }

    // MARK: Candidatos

    private func considerFile(_ path: String, st: stat, allocated: Int64) {
        let name = Self.name(of: path)
        guard !LargeOldRules.isHidden(name: name, flags: st.st_flags),
              !Exclusions.isExcluded(path: path, in: rules.exclusions) else { return }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard SafetyGuard.check(url).isAllowed else { return }

        let modified = Self.date(st.st_mtimespec)
        let accessed = Self.date(st.st_atimespec)
        let opened = useSpotlight ? LargeOldSpotlight.lastUsedDate(path: path) : nil
        // Modificação recente também é uso (ex.: disco de máquina virtual sendo gravado).
        let lastUsed = opened.map { max($0, modified) } ?? max(modified, accessed)
        let file = LargeOldFile(url: url, size: allocated,
                                kind: kind(forExtension: LargeOldRules.pathExtension(of: name), isDirectory: false),
                                lastUsed: lastUsed, modified: modified, isPackage: false,
                                lastUsedFromSpotlight: opened != nil)
        results.append(file)
        if st.st_nlink > 1 { hardLinks[url] = LargeOldHardLinkKey(device: st.st_dev, inode: st.st_ino) }
        delta.found += 1
        delta.bytes += allocated
    }

    private func considerPackage(_ path: String, st: stat) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard SafetyGuard.check(url).isAllowed else { return }
        let context = context
        let size = FileSizer.allocatedSize(of: url, isCancelled: { context.isCancelled })
        guard size >= minSize, !context.isCancelled else { return }

        // O acesso de uma pasta muda só de listá-la: aqui vale abertura (Spotlight) ou modificação.
        let modified = Self.date(st.st_mtimespec)
        let opened = useSpotlight ? LargeOldSpotlight.lastUsedDate(path: path) : nil
        let file = LargeOldFile(url: url, size: size,
                                kind: kind(forExtension: LargeOldRules.pathExtension(of: Self.name(of: path)), isDirectory: true),
                                lastUsed: opened.map { max($0, modified) } ?? modified, modified: modified,
                                isPackage: true, lastUsedFromSpotlight: opened != nil)
        results.append(file)
        delta.found += 1
        delta.bytes += size
    }

    private static func name(of path: String) -> Substring {
        guard let slash = path.lastIndex(of: "/") else { return path[...] }
        return path[path.index(after: slash)...]
    }

    private static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}

enum LargeOldPackageKind {
    /// Apps, frameworks, plug-ins: nem listados, nem abertos.
    case code
    /// Pacote de documento: listado inteiro.
    case document
    /// Pasta comum.
    case none
}

// MARK: - Spotlight e iCloud

enum LargeOldSpotlight {
    /// "Aberto em" do Finder (kMDItemLastUsedDate). nil fora do índice ou se nunca foi aberto.
    static func lastUsedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

enum LargeOldDataless {
    /// Nesta thread, tocar num item "sem dados" do iCloud falha em vez de baixá-lo.
    static func withoutMaterializing<T>(_ body: () -> T) -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }
        return body()
    }
}
