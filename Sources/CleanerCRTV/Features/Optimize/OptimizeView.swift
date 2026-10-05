import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
struct OptimizeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .optimize)
            ScanHero(symbol: Feature.optimize.symbol, tint: Feature.optimize.tint,
                     title: "Otimização", message: "Em construção.") {}
        }
    }
}
