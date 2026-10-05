import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
struct CleanupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .cleanup)
            ScanHero(symbol: Feature.cleanup.symbol, tint: Feature.cleanup.tint,
                     title: "Lixo do sistema", message: "Em construção.") {}
        }
    }
}
