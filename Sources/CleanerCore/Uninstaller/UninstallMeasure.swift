import Darwin
import Foundation

/// Tamanho alocado e modificação mais recente numa só passada (fts, sem seguir links nem cruzar volumes).
public enum UninstallMeasure {
    public struct Result: Sendable, Hashable {
        public var bytes: Int64
        /// Modificação mais recente do item ou de qualquer coisa dentro dele. nil se nada pôde ser lido.
        public var newest: Date?
    }

    public static func measure(_ url: URL, isCancelled: () -> Bool = { false }) -> Result {
        var total: Int64 = 0
        var newest: Int = Int.min
        var seenHardLinks = Set<UInt64>()
        url.path.withCString { cPath in
            guard let dup = strdup(cPath) else { return }
            defer { free(dup) }
            var paths: [UnsafeMutablePointer<CChar>?] = [dup, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }
            while let entry = fts_read(fts) {
                if isCancelled() { return }
                let info = Int32(entry.pointee.fts_info)
                switch info {
                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_DP:
                    guard let st = entry.pointee.fts_statp?.pointee else { continue }
                    newest = max(newest, st.st_mtimespec.tv_sec)
                    if info == FTS_F, st.st_nlink > 1, !seenHardLinks.insert(UInt64(st.st_ino)).inserted { continue }
                    total += Int64(st.st_blocks) * 512
                default:
                    continue
                }
            }
        }
        return Result(bytes: total, newest: newest == Int.min ? nil : Date(timeIntervalSince1970: TimeInterval(newest)))
    }
}

/// Paralelismo limitado (o disco não gosta de dezenas de leituras ao mesmo tempo).
enum UninstallConcurrency {
    /// `transform` em até `limit` tarefas simultâneas. O resultado segue a ordem da entrada.
    /// `onEach(feitos, total)` é chamado na tarefa da varredura (não na main).
    static func map<T: Sendable, R: Sendable>(
        _ items: [T],
        limit: Int,
        onEach: (@Sendable (Int, Int) -> Void)? = nil,
        _ transform: @escaping @Sendable (T) -> R
    ) async -> [R?] {
        var results = [R?](repeating: nil, count: items.count)
        guard !items.isEmpty else { return results }
        await withTaskGroup(of: (Int, R?).self) { group in
            var next = 0
            func enqueue() {
                let index = next
                let item = items[index]
                next += 1
                group.addTask { Task.isCancelled ? (index, nil) : (index, transform(item)) }
            }
            for _ in 0..<min(max(1, limit), items.count) { enqueue() }
            var done = 0
            while let (index, value) = await group.next() {
                results[index] = value
                done += 1
                onEach?(done, items.count)
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if next < items.count { enqueue() }
            }
        }
        return results
    }
}
