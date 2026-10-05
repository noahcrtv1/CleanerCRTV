import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
struct UninstallerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .uninstaller)
            ScanHero(symbol: Feature.uninstaller.symbol, tint: Feature.uninstaller.tint,
                     title: "Desinstalador", message: "Em construção.") {}
        }
    }
}
