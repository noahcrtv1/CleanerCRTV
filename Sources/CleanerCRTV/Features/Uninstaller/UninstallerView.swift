import CleanerCore
import SwiftUI

struct UninstallerView: View {
    @Environment(\.appModel) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: UninstallerModel { appModel.uninstaller }

    var body: some View {
        @Bindable var model = appModel.uninstaller
        VStack(spacing: 0) {
            FeatureHeader(feature: .uninstaller, subtitle: subtitle) {
                if model.hasScanned && !model.isDiscovering {
                    UninstallHeaderControls()
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.standard(reduceMotion), value: phase)
        .confirmationDialog(
            quitTitle,
            isPresented: Binding(get: { model.quitRequest != nil }, set: { if !$0 { model.quitRequest = nil } }),
            presenting: model.quitRequest
        ) { request in
            Button("Fechar e continuar") {
                Task { await model.quitAndContinue(request, appModel: appModel) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { request in
            Text("Para \(request.action == .reset ? "redefinir" : "desinstalar"), o CleanerCRTV precisa fechar "
                 + "\(UninstallFormat.list(request.running.map(\.name))). Se houver algo sem salvar, o app vai pedir para você salvar.")
        }
    }

    private var phase: Int {
        if model.isDiscovering { return 1 }
        if !model.hasScanned { return 0 }
        return model.tab == .apps ? 2 : 3
    }

    private var subtitle: String? {
        guard model.hasScanned, !model.isDiscovering else { return nil }
        let count = model.apps.count
        return "\(UninstallFormat.count(count, "app", "apps")) · \(model.totalAppBytes.formattedBytes) em aplicativos"
    }

    private var quitTitle: String {
        guard let request = model.quitRequest else { return "" }
        return request.running.count == 1 ? "\(request.running[0].name) está aberto" : "\(request.running.count) apps estão abertos"
    }

    @ViewBuilder private var content: some View {
        if model.isDiscovering {
            ScanningView(title: "Procurando apps…", progress: model.scanProgress, counter: model.scanCounter,
                         onCancel: { model.cancel() })
                .transition(.opacity)
        } else if !model.hasScanned {
            ScanHero(symbol: Feature.uninstaller.symbol, tint: Feature.uninstaller.tint,
                     title: "Desinstale apps por completo",
                     message: "Veja o tamanho e o último uso de cada app e remova junto as preferências, os caches "
                        + "e os restos que ele espalha pela Biblioteca.",
                     buttonTitle: "Escanear apps") {
                Task { await model.scan() }
            }
            .transition(.opacity)
        } else {
            switch model.tab {
            case .apps:
                UninstallAppsPane()
                    .transition(.opacity)
            case .orphans:
                UninstallOrphansPane()
                    .transition(.opacity)
            }
        }
    }
}

/// Abas, progresso dos tamanhos e "escanear de novo", à direita do cabeçalho.
private struct UninstallHeaderControls: View {
    @Environment(\.appModel) private var appModel

    var body: some View {
        @Bindable var model = appModel.uninstaller
        HStack(spacing: 12) {
            if model.isMeasuring {
                ProgressView(value: model.toMeasure > 0 ? Double(model.measured) / Double(model.toMeasure) : 0)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("Medindo tamanhos: \(model.measured) de \(model.toMeasure)")
                    .accessibilityLabel("Medindo tamanhos: \(model.measured) de \(model.toMeasure)")
                    .transition(.opacity)
            }
            Picker("Mostrar", selection: $model.tab) {
                Text("Apps").tag(UninstallTab.apps)
                Text(model.orphanGroups.isEmpty ? "Restos de apps removidos" : "Restos de apps removidos (\(model.orphanGroups.count))")
                    .tag(UninstallTab.orphans)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                Task { await model.scan() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle())
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(model.isScanning)
            .help("Escanear de novo")
            .accessibilityLabel("Escanear de novo")
        }
    }
}
