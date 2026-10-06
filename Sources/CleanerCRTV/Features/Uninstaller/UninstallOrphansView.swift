import CleanerCore
import SwiftUI

/// "Restos de apps removidos": nada vem marcado.
struct UninstallOrphansPane: View {
    @Environment(\.appModel) private var appModel

    var body: some View {
        let model = appModel.uninstaller
        if model.orphanGroups.isEmpty {
            if model.isScanning || model.isSearchingOrphans {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Procurando restos de apps removidos…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Nenhum resto por aqui", systemImage: "checkmark.seal")
                } description: {
                    Text("Não achamos sobras de apps que já saíram do seu Mac.")
                }
            }
        } else {
            UninstallOrphanList()
        }
    }
}

private struct UninstallOrphanList: View {
    @Environment(\.appModel) private var appModel

    var body: some View {
        let model = appModel.uninstaller
        let checked = model.checkedOrphanItems
        let checkedBytes = checked.reduce(Int64(0)) { $0 + $1.size }
        let totalBytes = model.orphanGroups.reduce(Int64(0)) { $0 + $1.size }

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(Brand.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(UninstallFormat.count(model.orphanGroups.count, "app removido deixou", "apps removidos deixaram")) "
                         + "\(totalBytes.formattedBytes) para trás")
                        .font(.callout.weight(.semibold))
                    Text("Nada vem marcado: confira cada item. Só entra o que está parado há mais de 30 dias e não pertence a nada instalado ou aberto.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Brand.orange.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }

            List {
                ForEach(model.orphanGroups) { group in
                    UninstallOrphanGroupRow(group: group)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            ActionBar(
                summary: checked.isEmpty ? "Nada marcado" : "\(UninstallFormat.count(checked.count, "item", "itens")) · \(checkedBytes.formattedBytes)",
                buttonTitle: "Remover selecionados…",
                enabled: !checked.isEmpty,
                tint: Brand.red,
                leading: {
                    if !checked.isEmpty {
                        Button("Desmarcar tudo") { model.checkedOrphans = [] }
                            .buttonStyle(.borderless)
                    }
                }
            ) {
                model.removeCheckedOrphans(appModel: appModel)
            }
        }
    }
}

private struct UninstallOrphanGroupRow: View {
    let group: UninstallOrphanGroup

    @Environment(\.appModel) private var appModel

    var body: some View {
        let model = appModel.uninstaller
        let checkedCount = group.items.reduce(0) { $0 + (model.checkedOrphans.contains($1.url) ? 1 : 0) }
        let state: TriStateCheckbox.CheckState = checkedCount == 0 ? .off : checkedCount == group.items.count ? .on : .mixed
        let expanded = Binding(
            get: { model.expandedOrphans.contains(group.key) },
            set: { if $0 { model.expandedOrphans.insert(group.key) } else { model.expandedOrphans.remove(group.key) } }
        )

        DisclosureGroup(isExpanded: expanded) {
            ForEach(group.items) { item in
                UninstallLeftoverRow(item: item, isChecked: model.checkedOrphans.contains(item.url), showsKind: true, inset: 0) {
                    model.setOrphansChecked([item], !model.checkedOrphans.contains(item.url))
                }
                .contextMenu { FileContextMenu(url: item.url) { model.forgetOrphan(item) } }
            }
        } label: {
            HStack(spacing: 10) {
                TriStateCheckbox(state: state, tint: Brand.red) {
                    model.setOrphansChecked(group.items, state != .on)
                }
                .accessibilityLabel("Marcar restos de \(group.key)")
                Image(systemName: "app.dashed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.key)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(group.size.formattedBytes)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
    }

    private var detail: String {
        let kinds = group.kinds.map(\.label).joined(separator: ", ")
        let count = UninstallFormat.count(group.items.count, "item", "itens")
        guard let newest = group.newest else { return "\(count) · \(kinds)" }
        return "\(count) · \(kinds) · mexido \(UninstallFormat.lastUsed(newest))"
    }
}
