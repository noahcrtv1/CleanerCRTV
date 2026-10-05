import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
struct LargeOldView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .largeOld)
            ScanHero(symbol: Feature.largeOld.symbol, tint: Feature.largeOld.tint,
                     title: "Grandes e antigos", message: "Em construção.") {}
        }
    }
}
