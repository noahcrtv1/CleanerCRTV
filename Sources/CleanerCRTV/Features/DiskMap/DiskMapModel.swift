import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
@Observable
@MainActor
final class DiskMapModel: ScanningFeature {
    var isScanning = false
    var badge: String? { nil }
    var summary: ScanSummary? { nil }

    func scan() async {}
    func cancel() {}
}
