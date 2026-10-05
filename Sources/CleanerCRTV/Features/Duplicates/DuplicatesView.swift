import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .duplicates)
            ScanHero(symbol: Feature.duplicates.symbol, tint: Feature.duplicates.tint,
                     title: "Duplicados", message: "Em construção.") {}
        }
    }
}
