import CleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(\.appModel) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !model.fullDiskAccess, model.selection != .monitor, model.selection != .history {
                    FullDiskAccessBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                // minHeight 0: listas longas não podem virar o tamanho mínimo da janela
                // (com .contentMinSize a janela cresceria até a lista inteira e empurraria o resto para fora).
                detail
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            }
            .animation(Motion.standard(reduceMotion), value: model.fullDiskAccess)
        }
        .sheet(item: $model.removalRequest) { request in
            RemovalSheet(request: request)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("Atenção", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .overlay {
            if model.showOpening {
                OpeningView { model.showOpening = false }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .toolbar(removing: .title)
        .background(WindowAccessor { model.mainWindow = $0 })
        .task {
            // `-autoScan YES` escaneia o módulo inicial ao abrir (testes).
            guard UserDefaults.standard.bool(forKey: "autoScan"), let feature = model.selection else { return }
            await model.scanner(for: feature)?.scan()
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .cleanup: CleanupView()
        case .largeOld: LargeOldView()
        case .duplicates: DuplicatesView()
        case .diskMap: DiskMapView()
        case .uninstaller: UninstallerView()
        case .optimize: OptimizeView()
        case .monitor: MonitorView()
        case .history: HistoryView()
        }
    }
}

/// Dá acesso à NSWindow da cena.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
