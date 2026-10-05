import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
struct DiskMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .diskMap)
            ScanHero(symbol: Feature.diskMap.symbol, tint: Feature.diskMap.tint,
                     title: "Mapa do disco", message: "Em construção.") {}
        }
    }
}
