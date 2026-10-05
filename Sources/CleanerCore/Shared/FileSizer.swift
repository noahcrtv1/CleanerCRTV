import Darwin
import Foundation

/// Tamanho ocupado em disco (blocos alocados, como "Tamanho no disco" do Finder).
/// Usa `fts` sem seguir links e sem atravessar para outros volumes; links físicos contam uma vez.
public enum FileSizer {
    /// Tamanho total de um arquivo ou pasta (recursivo). `isCancelled` é consultado a cada item.
    public static func allocatedSize(of url: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        var total: Int64 = 0
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
                    if info == FTS_F, st.st_nlink > 1, !seenHardLinks.insert(UInt64(st.st_ino)).inserted { continue }
                    total += Int64(st.st_blocks) * 512
                default:
                    continue
                }
            }
        }
        return total
    }

    /// Tamanho de um único item sem descer em pastas (lstat).
    public static func allocatedSize(ofItem url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return Int64(st.st_blocks) * 512
    }

    /// Existe no disco (sem seguir link)?
    public static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }
}
