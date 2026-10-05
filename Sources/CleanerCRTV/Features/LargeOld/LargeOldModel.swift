import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
@Observable
@MainActor
final class LargeOldModel: ScanningFeature {
    var isScanning = false
    var badge: String? { nil }

    func scan() async {}
    func cancel() {}
}
