import Darwin
import Foundation

/// Informação de clone APFS de um arquivo (getattrlist com ATTR_CMNEXT_CLONEID / PRIVATESIZE).
/// Em volumes que não informam (HFS+, exFAT, rede), os campos vêm nil e o arquivo conta como cópia comum.
struct DuplicateCloneInfo: Sendable, Equatable {
    var cloneID: UInt64?
    var privateSize: Int64?

    static func read(path: String) -> DuplicateCloneInfo {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        // Os atributos CMNEXT vão no campo forkattr e exigem FSOPT_ATTR_CMN_EXTENDED.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID)
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)

        var buffer = [UInt8](repeating: 0, count: 128)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options)
        }
        guard status == 0 else { return DuplicateCloneInfo() }

        return buffer.withUnsafeBytes { raw in
            // u_int32_t tamanho | attribute_set_t devolvidos | atributos na ordem dos bits.
            let length = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            var offset = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            offset += MemoryLayout<attribute_set_t>.size
            var info = DuplicateCloneInfo()
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0, offset + 8 <= min(length, raw.count) {
                info.privateSize = Int64(raw.loadUnaligned(fromByteOffset: offset, as: off_t.self))
                offset += 8
            }
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0, offset + 8 <= min(length, raw.count) {
                let id = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                info.cloneID = id == 0 ? nil : id
            }
            return info
        }
    }
}
