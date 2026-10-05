import AppKit
import CleanerCore
import SwiftUI

/// Pedido de remoção aguardando confirmação na folha `RemovalSheet`.
struct RemovalRequest: Identifiable {
    let id = UUID()
    var items: [RemovalItem]
    /// Nome do módulo (vai para o histórico).
    var source: String
    /// Título da folha. Padrão: "Remover N itens?"
    var title: String?
    /// Força um modo (ex.: esvaziar a Lixeira é sempre permanente). nil = usuário escolhe.
    var forcedMode: RemovalMode?
    /// Aviso extra mostrado na folha (ex.: "3 apps estão abertos e serão fechados").
    var note: String?
    var completion: @MainActor (RemovalReport) -> Void
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String = "checkmark.circle.fill"
    var isError = false
}

@Observable
@MainActor
final class AppModel {
    var selection: Feature? = .dashboard
    var showOpening = !UserDefaults.standard.bool(forKey: "skipOpening")
    var fullDiskAccess = FullDiskAccess.isGranted
    var removalRequest: RemovalRequest?
    var toast: Toast?
    var alert: String?

    // Módulos (cada um guarda o próprio estado; sobrevivem à troca de tela).
    let cleanup = CleanupModel()
    let largeOld = LargeOldModel()
    let duplicates = DuplicatesModel()
    let diskMap = DiskMapModel()
    let uninstaller = UninstallerModel()
    let optimize = OptimizeModel()
    let monitor = MonitorModel()
    let history = HistoryModel()

    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Modo padrão da folha de confirmação (Ajustes ▸ Geral).
    var defaultRemovalMode: RemovalMode {
        RemovalMode(rawValue: UserDefaults.standard.string(forKey: "removalMode") ?? "") ?? .trash
    }

    func badge(for feature: Feature) -> String? {
        switch feature {
        case .dashboard, .history, .monitor: nil
        case .cleanup: cleanup.badge
        case .largeOld: largeOld.badge
        case .duplicates: duplicates.badge
        case .diskMap: diskMap.badge
        case .uninstaller: uninstaller.badge
        case .optimize: optimize.badge
        }
    }

    // MARK: - Remoção

    /// Abre a confirmação. Ao terminar, `completion` recebe o relatório (use `report.removedSet`
    /// para tirar da lista o que saiu). Nada é removido sem passar por aqui.
    func requestRemoval(
        _ items: [RemovalItem],
        source: String,
        title: String? = nil,
        forcedMode: RemovalMode? = nil,
        note: String? = nil,
        completion: @escaping @MainActor (RemovalReport) -> Void = { _ in }
    ) {
        guard !items.isEmpty else { return }
        removalRequest = RemovalRequest(items: items, source: source, title: title,
                                        forcedMode: forcedMode, note: note, completion: completion)
    }

    /// Chamado pela folha depois da confirmação.
    func performRemoval(_ request: RemovalRequest, mode: RemovalMode,
                        progress: @escaping @MainActor @Sendable (Int, Int) -> Void) async {
        let report = await Remover.remove(request.items, mode: mode, source: request.source, progress: progress)
        request.completion(report)
        history.reload()
        let count = report.removed.count
        let size = report.bytes.formattedBytes
        if report.failed.isEmpty {
            showToast(mode == .trash
                      ? "\(count) \(count == 1 ? "item foi" : "itens foram") para a Lixeira · \(size)"
                      : "\(count) \(count == 1 ? "item apagado" : "itens apagados") · \(size) liberados")
        } else {
            let first = report.failed[0]
            showToast("\(count) removidos, \(report.failed.count) falharam (\(first.url.lastPathComponent): \(first.reason))",
                      symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    // MARK: - Avisos

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill", isError: Bool = false) {
        toastTask?.cancel()
        withAnimation(Motion.standard) { toast = Toast(text: text, symbol: symbol, isError: isError) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 7 : 4))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.standard) { self?.toast = nil }
        }
    }

    func refreshPermissions() {
        fullDiskAccess = FullDiskAccess.isGranted
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }
}
