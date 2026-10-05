import Darwin
import Foundation

/// "Acesso Total ao Disco" (TCC). Sem ele, várias pastas de ~/Library aparecem vazias ou dão erro.
public enum FullDiskAccess {
    /// Ajustes ▸ Privacidade e Segurança ▸ Acesso Total ao Disco.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Testa abrindo arquivos que só são legíveis com o acesso concedido.
    public static var isGranted: Bool {
        let probes = [
            Paths.library("Application Support/com.apple.TCC/TCC.db").path,
            Paths.library("Safari/Bookmarks.plist").path,
            Paths.library("Containers/com.apple.stocks").path,
        ]
        for probe in probes {
            var st = stat()
            guard lstat(probe, &st) == 0 else { continue }   // não existe neste Mac: tenta o próximo
            let fd = open(probe, O_RDONLY)
            if fd >= 0 { close(fd); return true }
            return false
        }
        return false
    }
}
