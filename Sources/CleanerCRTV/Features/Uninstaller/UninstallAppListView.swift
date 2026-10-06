import CleanerCore
import SwiftUI

/// Lista de apps à esquerda + detalhe à direita.
struct UninstallAppsPane: View {
    var body: some View {
        HStack(spacing: 0) {
            UninstallAppList()
                .frame(width: 330)
            Divider()
            UninstallDetailPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct UninstallAppList: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = appModel.uninstaller
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    UninstallSearchField(text: $model.searchText)
                    Menu {
                        Picker("Ordenar por", selection: $model.sort) {
                            ForEach(UninstallSort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Ordenar por \(model.sort.title.lowercased())")
                    .accessibilityLabel("Ordenar")
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(UninstallAppFilter.allCases) { filter in
                            UninstallChip(title: filter.title, count: model.filterCounts[filter] ?? 0,
                                          isOn: model.appFilter == filter) {
                                withAnimation(Motion.quick(reduceMotion)) { model.appFilter = filter }
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 10)

            Divider()

            if model.visibleApps.isEmpty {
                Group {
                    if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("Nenhum app aqui", systemImage: "app.dashed",
                                               description: Text("Nenhum app combina com o filtro \"\(model.appFilter.title)\"."))
                    } else {
                        ContentUnavailableView.search(text: model.searchText)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visibleApps) { app in
                        UninstallAppRow(app: app,
                                        isChecked: model.selection.contains(app.url),
                                        isRunning: model.isRunning(app)) {
                            model.toggle(app)
                        }
                        .tag(app.url)
                        .contextMenu {
                            Button("Abrir") { Reveal.open(app.url) }
                            FileContextMenu(url: app.url) { model.forget(app) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    let targets = model.selectedApps
                    Task { await model.begin(.uninstall, apps: targets, appModel: appModel) }
                }
            }

            Divider()
            UninstallListFooter()
        }
    }
}

private struct UninstallListFooter: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let model = appModel.uninstaller
        HStack(spacing: 6) {
            if model.selection.count > 1 {
                Text("\(model.selection.count) selecionados")
                Spacer()
                Button("Limpar seleção") { model.selection = [] }
                    .buttonStyle(.borderless)
            } else {
                Text(model.visibleApps.count == model.apps.count
                     ? UninstallFormat.count(model.apps.count, "app", "apps")
                     : "\(model.visibleApps.count) de \(model.apps.count) apps")
                Spacer()
                Text("⌘-clique escolhe vários")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct UninstallAppRow: View {
    let app: UninstallApp
    let isChecked: Bool
    let isRunning: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TriStateCheckbox(state: isChecked ? .on : .off, tint: Brand.red, action: onToggle)
                .disabled(!app.canUninstall)
                .opacity(app.canUninstall ? 1 : 0.35)
                .accessibilityLabel(isChecked ? "Desmarcar \(app.name)" : "Marcar \(app.name)")
            FileIcon(url: app.url, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .lineLimit(1)
                    if isRunning {
                        Circle()
                            .fill(Brand.green)
                            .frame(width: 6, height: 6)
                            .help("Aberto agora")
                            .accessibilityLabel("Aberto agora")
                    }
                    if !app.canUninstall {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help(app.blockReason ?? "")
                            .accessibilityLabel("Protegido")
                    }
                }
                Text(UninstallFormat.lastUsed(app.lastUsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let size = app.size {
                Text(size.formattedBytes)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Medindo")
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }
}

private struct UninstallSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar apps", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Filtro em pílula, com contagem.
private struct UninstallChip: View {
    let title: String
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isOn ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isOn ? AnyShapeStyle(Brand.red.gradient) : AnyShapeStyle(.quaternary.opacity(0.6))))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
