import Darwin
import Foundation

/// Uma entrada de pasta lida por `getattrlistbulk`. `name` só vale dentro do callback.
struct DiskMapRawEntry {
    var name: UnsafePointer<CChar>?
    var objectType: UInt32 = 0
    var device: Int32 = 0
    var flags: UInt32 = 0
    var fileID: UInt64 = 0
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 1
    var allocatedSize: Int64 = 0
    var logicalSize: Int64 = 0
    var error: UInt32 = 0

    var isDirectory: Bool { objectType == DiskMapDirectoryReader.vDir }
    var isRegularFile: Bool { objectType == DiskMapDirectoryReader.vReg }
    var isSymlink: Bool { objectType == DiskMapDirectoryReader.vLnk }
}

/// Lê uma pasta inteira com `getattrlistbulk`: nome, tipo e tamanhos de dezenas de entradas por
/// chamada ao sistema, em vez de um `lstat` por arquivo. É o que deixa a varredura de milhões de
/// arquivos rápida.
enum DiskMapDirectoryReader {
    // sys/attr.h e sys/vnode.h (valores fixos da ABI).
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnFlags: UInt32 = 0x0004_0000
    static let cmnFileID: UInt32 = 0x0200_0000
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let dirMountStatus: UInt32 = 0x0000_0004
    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileTotalSize: UInt32 = 0x0000_0002
    static let fileAllocSize: UInt32 = 0x0000_0004

    static let mountPoint: UInt32 = 0x0000_0001
    static let mountTrigger: UInt32 = 0x0000_0002
    /// SF_DATALESS: conteúdo só na nuvem.
    static let datalessFlag: UInt32 = 0x4000_0000

    static let vReg: UInt32 = 1
    static let vDir: UInt32 = 2
    static let vLnk: UInt32 = 5

    static let bufferSize = 256 * 1024

    /// Chama `body` para cada entrada (sem "." e ".."). Devolve 0 ou o `errno` que parou a leitura.
    static func forEachEntry(fd: Int32, buffer: UnsafeMutableRawPointer, capacity: Int,
                             _ body: (inout DiskMapRawEntry) -> Void) -> Int32 {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnDevID | cmnObjType | cmnFlags | cmnFileID
        request.dirattr = dirMountStatus
        request.fileattr = fileLinkCount | fileTotalSize | fileAllocSize

        while true {
            let count = withUnsafeMutablePointer(to: &request) {
                getattrlistbulk(fd, UnsafeMutableRawPointer($0), buffer, capacity, 0)
            }
            if count == 0 { return 0 }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                return code
            }
            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let entryStart = cursor
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                guard length > 0 else { return EIO }
                cursor = entryStart + length

                var field = entryStart + MemoryLayout<UInt32>.size
                // attribute_set_t: common, vol, dir, file, fork
                let returnedCommon = field.loadUnaligned(as: UInt32.self)
                let returnedDir = field.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                let returnedFile = field.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                field += MemoryLayout<attribute_set_t>.size

                var entry = DiskMapRawEntry()
                // ATTR_CMN_ERROR vem logo depois do conjunto devolvido (getattrlistbulk(2)).
                if returnedCommon & cmnError != 0 {
                    entry.error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returnedCommon & cmnName != 0 {
                    let offset = Int(field.loadUnaligned(as: Int32.self))
                    entry.name = (field + offset).assumingMemoryBound(to: CChar.self)
                    field += MemoryLayout<attrreference_t>.size
                }
                if returnedCommon & cmnDevID != 0 {
                    entry.device = field.loadUnaligned(as: Int32.self)
                    field += 4
                }
                if returnedCommon & cmnObjType != 0 {
                    entry.objectType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returnedCommon & cmnFlags != 0 {
                    entry.flags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returnedCommon & cmnFileID != 0 {
                    entry.fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if returnedDir & dirMountStatus != 0 {
                    entry.mountStatus = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returnedFile & fileLinkCount != 0 {
                    entry.linkCount = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returnedFile & fileTotalSize != 0 {
                    entry.logicalSize = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                if returnedFile & fileAllocSize != 0 {
                    entry.allocatedSize = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                guard entry.name != nil else { continue }
                body(&entry)
            }
        }
    }

    /// Lê os arquivos (não pastas) de uma pasta. Usado para abrir o grupo "N arquivos menores".
    static func listFiles(atPath path: String, skipping names: Set<String>, excluded: Set<String>) -> [DiskMapNode]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var files: [DiskMapNode] = []
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let result = forEachEntry(fd: fd, buffer: buffer, capacity: bufferSize) { entry in
            guard entry.error == 0, !entry.isDirectory, let raw = entry.name else { return }
            let name = String(cString: raw)
            guard !names.contains(name), !excluded.contains(prefix + name) else { return }
            var flags: DiskMapNode.Flags = []
            if entry.isSymlink { flags.insert(.symlink) }
            files.append(DiskMapNode(name: name, flags: flags, size: max(0, entry.allocatedSize),
                                     logicalSize: max(0, entry.logicalSize), fileCount: 1))
        }
        if result != 0, files.isEmpty { return nil }
        files.sort(by: DiskMapNode.ordered)
        return files
    }
}
