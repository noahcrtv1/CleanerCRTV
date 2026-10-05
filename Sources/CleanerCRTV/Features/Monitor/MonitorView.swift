import CleanerCore
import SwiftUI

// STUB — substituir pela implementação do módulo.
struct MonitorView: View {
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .monitor)
            Spacer()
        }
    }
}

/// Conteúdo da janelinha do ícone na barra de menus. STUB.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CleanerCRTV").font(.headline)
            Button("Abrir CleanerCRTV") {
                openWindow(id: "main")
                NSApp.activate()
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Rótulo do item na barra de menus. STUB.
struct MenuBarLabel: View {
    var body: some View {
        Image(systemName: "sparkles")
    }
}
