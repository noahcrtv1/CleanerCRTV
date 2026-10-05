import CleanerCore
import SwiftUI

@Observable
@MainActor
final class HistoryModel {
    var entries: [HistoryEntry] = []

    init() { reload() }

    func reload() { entries = HistoryStore.shared.load() }

    func clear() {
        HistoryStore.shared.clear()
        reload()
    }

    var totals: (permanent: Int64, trashed: Int64) {
        (entries.filter { $0.mode == .permanent }.reduce(0) { $0 + $1.bytes },
         entries.filter { $0.mode == .trash }.reduce(0) { $0 + $1.bytes })
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<UUID> = []
    @State private var confirmClear = false

    var body: some View {
        let history = model.history
        VStack(spacing: 0) {
            FeatureHeader(feature: .history) {
                if !history.entries.isEmpty {
                    Button("Limpar histórico") { confirmClear = true }
                }
            }
            if history.entries.isEmpty {
                ContentUnavailableView("Nada removido ainda", systemImage: "clock.arrow.circlepath",
                                       description: Text("Cada limpeza fica registrada aqui, com a lista dos arquivos."))
            } else {
                HStack(spacing: 24) {
                    StatTile(title: "Apagado de vez", value: history.totals.permanent.formattedBytes, tint: Brand.red)
                    StatTile(title: "Enviado à Lixeira", value: history.totals.trashed.formattedBytes, tint: Brand.teal)
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
                List {
                    ForEach(history.entries) { entry in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(entry.id) },
                            set: { if $0 { expanded.insert(entry.id) } else { expanded.remove(entry.id) } })) {
                            ForEach(entry.paths.prefix(200), id: \.self) { path in
                                Text(path.replacingOccurrences(of: Paths.home.path, with: "~"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            if entry.paths.count > 200 || entry.itemCount > entry.paths.count {
                                Text("+ \(entry.itemCount - min(200, entry.paths.count)) itens")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            ForEach(entry.failures, id: \.self) { failure in
                                Label(failure, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(Brand.orange)
                                    .lineLimit(2)
                            }
                        } label: {
                            HistoryRow(entry: entry)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange)) { _ in history.reload() }
        .confirmationDialog("Apagar o histórico?", isPresented: $confirmClear) {
            Button("Apagar histórico", role: .destructive) { history.clear() }
        } message: {
            Text("Só o registro é apagado; os arquivos não voltam.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.mode == .trash ? "trash" : "xmark.bin.fill")
                .foregroundStyle(entry.mode == .trash ? Brand.teal : Brand.red)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.source).font(.body.weight(.semibold))
                Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.itemCount) \(entry.itemCount == 1 ? "item" : "itens") · \(entry.mode == .trash ? "Lixeira" : "permanente")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !entry.failures.isEmpty {
                Label("\(entry.failures.count)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Brand.orange)
            }
            Text(entry.bytes.formattedBytes).font(.body.monospacedDigit().weight(.medium))
        }
        .padding(.vertical, 4)
    }
}
