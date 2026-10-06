import CleanerCore
import SwiftUI

/// Lado direito: nada, um app ou vários.
struct UninstallDetailPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let selected = appModel.uninstaller.selectedApps
        switch selected.count {
        case 0:
            ContentUnavailableView {
                Label("Escolha um app", systemImage: "hand.point.left")
            } description: {
                Text("Selecione um app na lista para ver o que ele deixa no seu Mac. Marque vários para desinstalar de uma vez.")
            }
        case 1:
            UninstallAppDetail(app: selected[0])
                .id(selected[0].url)
        default:
            UninstallBatchDetail(apps: selected)
        }
    }
}

// MARK: - Um app

private struct UninstallAppDetail: View {
    let app: UninstallApp

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: UninstallerModel { appModel.uninstaller }

    var body: some View {
        let items = model.leftovers[app.url] ?? []
        let checked = items.filter { model.checkedLeftovers.contains($0.url) }
        let checkedBytes = checked.reduce(Int64(0)) { $0 + $1.size }
        let isLoading = model.loadingLeftovers.contains(app.url)

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    stats(leftoverBytes: items.reduce(0) { $0 + $1.size }, isLoading: isLoading)
                    if let reason = app.blockReason {
                        Label(reason, systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.orange.opacity(0.1)))
                    } else {
                        leftoversSection(items: items, isLoading: isLoading)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            ActionBar(
                summary: actionSummary(checked: checked.count, bytes: checkedBytes),
                buttonTitle: "Desinstalar…",
                enabled: app.canUninstall && model.busyText == nil,
                tint: Brand.red,
                leading: {
                    if let busy = model.busyText {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout).foregroundStyle(.secondary)
                    } else if app.canUninstall {
                        Button("Redefinir") {
                            Task { await model.begin(.reset, apps: [app], appModel: appModel) }
                        }
                        .disabled(checked.isEmpty)
                        .help("Apaga só os restos marcados: o app fica instalado e volta ao estado de primeira abertura")
                    }
                }
            ) {
                Task { await model.begin(.uninstall, apps: [app], appModel: appModel) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            FileIcon(url: app.url, size: 84)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(2)
                Text([app.version.map { "Versão \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if model.isRunning(app) { UninstallTag(text: "Aberto", symbol: "circle.fill", tint: Brand.green) }
                    if app.isAppStore { UninstallTag(text: "App Store", symbol: "bag.fill", tint: Brand.teal) }
                    if app.isApple { UninstallTag(text: "Apple", symbol: "apple.logo", tint: .gray) }
                    if let team = app.teamID { UninstallTag(text: "Equipe \(team)", symbol: "checkmark.seal.fill", tint: Brand.violet) }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button {
                Reveal.inFinder(app.url)
            } label: {
                Image(systemName: "folder")
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle())
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Mostrar no Finder")
            .accessibilityLabel("Mostrar no Finder")
        }
    }

    private func stats(leftoverBytes: Int64, isLoading: Bool) -> some View {
        GlassCard(padding: 16) {
            HStack(alignment: .top, spacing: 0) {
                StatTile(title: "App", value: app.size.map(\.formattedBytes) ?? "medindo…", tint: Brand.red, symbol: "app")
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatTile(title: "Restos", value: isLoading && leftoverBytes == 0 ? "…" : leftoverBytes.formattedBytes,
                         tint: Brand.magenta, symbol: "archivebox")
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatTile(title: "Último uso", value: UninstallFormat.lastUsed(app.lastUsed), tint: Brand.violet, symbol: "clock")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func leftoversSection(items: [UninstallLeftover], isLoading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Restos na Biblioteca")
                .font(.headline)
            Text("Já vem marcado o que o app recria sozinho. Pastas que podem guardar seus documentos ficam para você decidir.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if isLoading && items.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Procurando restos…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if items.isEmpty {
            Label("Nenhum resto encontrado. Desinstalar remove só o app.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(UninstallLeftoverGroup.grouped(items)) { group in
                    UninstallLeftoverGroupCard(group: group)
                }
            }
            .animation(Motion.standard(reduceMotion), value: items.map(\.url))
        }
    }

    private func actionSummary(checked: Int, bytes: Int64) -> String {
        guard app.canUninstall else { return "Protegido" }
        let total = (app.size ?? 0) + bytes
        let rest = checked == 0 ? "só o app" : "app + \(UninstallFormat.count(checked, "resto", "restos"))"
        return "\(rest) · \(total.formattedBytes)"
    }
}

/// Um tipo de resto (Preferências, Caches…) com seus itens.
private struct UninstallLeftoverGroupCard: View {
    let group: UninstallLeftoverGroup

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let model = appModel.uninstaller
        let checkedCount = group.items.reduce(0) { $0 + (model.checkedLeftovers.contains($1.url) ? 1 : 0) }
        let state: TriStateCheckbox.CheckState = checkedCount == 0 ? .off : checkedCount == group.items.count ? .on : .mixed

        GlassCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TriStateCheckbox(state: state, tint: Brand.red) {
                        model.setChecked(group.items, state != .on)
                    }
                    .accessibilityLabel("Marcar \(group.kind.label)")
                    Image(systemName: group.kind.symbol)
                        .foregroundStyle(Brand.red)
                        .frame(width: 18)
                    Text(group.kind.label).font(.body.weight(.semibold))
                    Text("\(group.items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    SizeText(bytes: group.size, weight: .semibold)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().padding(.leading, 14)
                ForEach(group.items) { item in
                    UninstallLeftoverRow(item: item, isChecked: model.checkedLeftovers.contains(item.url)) {
                        model.setChecked([item], !model.checkedLeftovers.contains(item.url))
                    }
                    .contextMenu { FileContextMenu(url: item.url) { model.forgetLeftover(item) } }
                    if item.id != group.items.last?.id { Divider().padding(.leading, 48) }
                }
            }
        }
    }
}

/// Linha de um resto (também usada nos restos de apps removidos).
struct UninstallLeftoverRow: View {
    let item: UninstallLeftover
    let isChecked: Bool
    var showsKind = false
    var inset: CGFloat = 14
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TriStateCheckbox(state: isChecked ? .on : .off, tint: Brand.red, action: onToggle)
                .accessibilityLabel(isChecked ? "Desmarcar \(item.url.lastPathComponent)" : "Marcar \(item.url.lastPathComponent)")
            FileIcon(url: item.url, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(showsKind ? "\(item.kind.label) · \(UninstallFormat.displayPath(item.url))" : UninstallFormat.displayPath(item.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            UninstallConfidenceTag(confidence: item.confidence)
            Text(item.size.formattedBytes)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
    }
}

struct UninstallConfidenceTag: View {
    let confidence: UninstallConfidence

    var body: some View {
        let tint = confidence == .high ? Brand.green : Brand.orange
        Text(confidence.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .help(confidence == .high
                  ? "Confiança alta: o nome é o identificador do app."
                  : "Confiança média: confira antes de remover.")
            .accessibilityLabel("Confiança \(confidence.label)")
    }
}

private struct UninstallTag: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).imageScale(.small)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - Vários apps

private struct UninstallBatchDetail: View {
    let apps: [UninstallApp]

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let model = appModel.uninstaller
        let allowed = apps.filter(\.canUninstall)
        let leftoverBytes = allowed.reduce(Int64(0)) { sum, app in
            sum + model.checkedItems(of: app).reduce(0) { $0 + $1.size }
        }
        let appBytes = allowed.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(apps.count) apps selecionados")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("Cada app sai com os restos já marcados. Para escolher item por item, selecione um app só.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    GlassCard(padding: 16) {
                        HStack(spacing: 0) {
                            StatTile(title: "Apps", value: appBytes.formattedBytes, tint: Brand.red, symbol: "app")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StatTile(title: "Restos marcados", value: leftoverBytes.formattedBytes, tint: Brand.magenta, symbol: "archivebox")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StatTile(title: "Total", value: (appBytes + leftoverBytes).formattedBytes, tint: Brand.violet, symbol: "sum")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GlassCard(padding: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(apps) { app in
                                UninstallBatchRow(app: app)
                                if app.id != apps.last?.id { Divider().padding(.leading, 56) }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            ActionBar(
                summary: "\(UninstallFormat.count(allowed.count, "app", "apps")) · \((appBytes + leftoverBytes).formattedBytes)",
                buttonTitle: allowed.count == 1 ? "Desinstalar…" : "Desinstalar \(allowed.count) apps…",
                enabled: !allowed.isEmpty && model.busyText == nil,
                tint: Brand.red,
                leading: {
                    if let busy = model.busyText {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout).foregroundStyle(.secondary)
                    } else if allowed.count < apps.count {
                        Label("\(apps.count - allowed.count) protegidos ficam de fora", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            ) {
                Task { await model.begin(.uninstall, apps: apps, appModel: appModel) }
            }
        }
    }
}

private struct UninstallBatchRow: View {
    let app: UninstallApp

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let model = appModel.uninstaller
        let checked = model.checkedItems(of: app)
        HStack(spacing: 12) {
            FileIcon(url: app.url, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Group {
                    if let reason = app.blockReason {
                        Text(reason)
                    } else if model.loadingLeftovers.contains(app.url) {
                        Text("Procurando restos…")
                    } else {
                        Text(checked.isEmpty ? "Sem restos marcados" : "+ \(UninstallFormat.count(checked.count, "resto", "restos")) · "
                             + checked.reduce(Int64(0)) { $0 + $1.size }.formattedBytes)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.isRunning(app) { UninstallTag(text: "Aberto", symbol: "circle.fill", tint: Brand.green) }
            if app.canUninstall {
                Text(app.size?.formattedBytes ?? "…")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.tertiary).accessibilityLabel("Protegido")
            }
            Button {
                model.toggle(app)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Tirar da seleção")
            .accessibilityLabel("Tirar \(app.name) da seleção")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .opacity(app.canUninstall ? 1 : 0.6)
    }
}
