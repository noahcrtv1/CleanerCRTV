import CleanerCore
import SwiftUI

/// "Lixo do sistema": categorias à esquerda, itens da categoria aberta à direita, "Limpar" no rodapé.
struct CleanupView: View {
    @Environment(\.appModel) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: CleanupModel { app.cleanup }

    private enum Phase { case intro, scanning, empty, results }

    private var phase: Phase {
        if model.isScanning { return .scanning }
        if !model.hasResults { return .intro }
        return model.results.isEmpty ? .empty : .results
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .cleanup) {
                if phase == .results || phase == .empty {
                    Button(action: startScan) {
                        Label("Escanear de novo", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .transition(.opacity)
                }
            }
            Group {
                switch phase {
                case .intro:
                    ScanHero(symbol: Feature.cleanup.symbol, tint: Feature.cleanup.tint, title: "Lixo do sistema",
                             message: "Caches, registros, restos de desenvolvimento, anexos do Mail e instaladores esquecidos. Nada é apagado sem a sua confirmação.",
                             action: startScan)
                case .scanning:
                    ScanningView(title: "Procurando lixo…", detail: scanDetail, progress: model.progress?.fraction,
                                 counter: scanCounter, onCancel: model.cancel)
                case .empty:
                    ContentUnavailableView {
                        Label("Tudo limpo", systemImage: "sparkles")
                    } description: {
                        if model.inaccessibleCount > 0 {
                            Text("Nada para limpar nas pastas que o app consegue ler. Com Acesso Total ao Disco, caches de outros apps, Safari, Mail e a Lixeira também entram.")
                        } else {
                            Text("Não sobrou cache, registro nem resto de instalação para limpar. Volte daqui a alguns dias.")
                        }
                    } actions: {
                        if model.inaccessibleCount > 0 {
                            Button("Abrir Ajustes", action: app.openFullDiskAccessSettings)
                        }
                        Button("Escanear de novo", action: startScan)
                            .buttonStyle(.gradient)
                    }
                case .results:
                    CleanupResultsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(Motion.standard(reduceMotion), value: phase)
    }

    private func startScan() {
        Task { await model.scan() }
    }

    private var scanDetail: String? {
        model.progress?.currentPath.map(CleanupFormat.abbreviated)
    }

    private var scanCounter: String? {
        guard let progress = model.progress else { return "Lendo as pastas de cache…" }
        switch progress.stage {
        case .discovering: return "Lendo as pastas de cache…"
        case .measuring:
            return "\(CleanupFormat.items(progress.foundCount)) · \(progress.foundBytes.formattedBytes)"
        }
    }
}

// MARK: - Resultado

private struct CleanupResultsView: View {
    let model: CleanupModel
    @Environment(\.appModel) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CleanupCategoryPane(model: model)
                    .frame(width: 292)
                Divider()
                CleanupDetailPane(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ActionBar(summary: summary, buttonTitle: "Limpar", enabled: model.selectedCount > 0) {
                HStack(spacing: 14) {
                    Button("Seleção recomendada", action: model.selectRecommended)
                    Button("Desmarcar tudo", action: model.deselectAll)
                        .disabled(model.selectedCount == 0)
                }
                .buttonStyle(.borderless)
                .font(.callout)
            } action: {
                clean()
            }
        }
    }

    private var summary: String {
        guard model.selectedCount > 0 else { return "Nada selecionado" }
        return "\(CleanupFormat.items(model.selectedCount)) · \(model.selectedBytes.formattedBytes) selecionados"
    }

    private func clean() {
        let items = model.recommendedItems
        guard !items.isEmpty else { return }
        let busy = model.selectedBusyCount
        let note: String? = busy > 0
            ? "\(busy == 1 ? "1 item é de um app aberto ou está em uso" : "\(busy) itens são de apps abertos ou estão em uso"). Feche os apps antes para evitar erros."
            : nil
        let model = self.model
        let animation = Motion.standard(reduceMotion)
        app.requestRemoval(items, source: Feature.cleanup.title,
                           title: "Limpar \(CleanupFormat.items(items.count))?", note: note) { report in
            withAnimation(animation) { model.didRemove(report) }
        }
    }
}

// MARK: - Coluna das categorias

private struct CleanupCategoryPane: View {
    let model: CleanupModel
    @Environment(\.appModel) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lixo encontrado")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.totalBytes.formattedBytes)
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Brand.gradient)
                    .contentTransition(.numericText())
                Text("\(CleanupFormat.items(model.totalCount)) em \(categoryCount) \(categoryCount == 1 ? "categoria" : "categorias")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.results) { result in
                        CleanupCategoryRow(model: model, result: result)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }

            if model.inaccessibleCount > 0 {
                CleanupAccessNotice(count: model.inaccessibleCount) { app.openFullDiskAccessSettings() }
                    .padding(12)
            }
        }
    }

    private var categoryCount: Int { model.results.filter { !$0.isTrash }.count }
}

private struct CleanupCategoryRow: View {
    let model: CleanupModel
    let result: CleanupCategoryResult
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFocused: Bool { model.focused == result.id }
    private var tint: Color { CleanupStyle.tint(result.id) }

    var body: some View {
        HStack(spacing: 10) {
            if result.isTrash {
                Color.clear.frame(width: 15, height: 15)
            } else {
                TriStateCheckbox(state: model.checkState(result.id), tint: tint) {
                    model.toggleCategory(result.id)
                }
                .accessibilityLabel("Marcar \(result.category.title)")
            }
            CleanupSymbolTile(symbol: result.category.symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.category.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(result.bytes.formattedBytes)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(isFocused ? .primary : .secondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? tint.opacity(0.16) : .clear)
        }
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { focus() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(result.category.title), \(result.bytes.formattedBytes)")
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { focus() }
    }

    private var subtitle: String {
        let count = result.entries.count
        if result.isTrash { return "\(CleanupFormat.items(count)) · esvazie à parte" }
        let selected = model.selectedPerCategory[result.id] ?? 0
        if selected == count { return CleanupFormat.items(count) }
        return "\(CleanupFormat.number(selected)) de \(CleanupFormat.number(count)) marcados"
    }

    private func focus() {
        withAnimation(Motion.quick(reduceMotion)) { model.focused = result.id }
    }
}

private struct CleanupAccessNotice: View {
    let count: Int
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(count) \(count == 1 ? "pasta precisa" : "pastas precisam") de Acesso Total ao Disco",
                  systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.orange)
            Text("Sem ele, caches de outros apps, Safari, Mail e a Lixeira ficam de fora.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Abrir Ajustes", action: openSettings)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Brand.orange.opacity(0.12)), in: .rect(cornerRadius: 14))
    }
}

// MARK: - Itens da categoria aberta

private struct CleanupDetailPane: View {
    @Bindable var model: CleanupModel
    @Environment(\.appModel) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted: Set<URL> = []

    private var result: CleanupCategoryResult? { model.results.first { $0.id == model.focused } }

    var body: some View {
        if let result {
            VStack(spacing: 0) {
                header(result)
                Divider()
                list(result)
            }
            .onChange(of: model.focused) { highlighted = [] }
        } else {
            ContentUnavailableView("Escolha uma categoria", systemImage: "sidebar.left",
                                   description: Text("Os itens dela aparecem aqui."))
        }
    }

    // Cabeçalho: o que é, quanto ocupa, marcar tudo e ordem.
    private func header(_ result: CleanupCategoryResult) -> some View {
        let tint = CleanupStyle.tint(result.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CleanupSymbolTile(symbol: result.category.symbol, tint: tint, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.category.title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(result.category.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(result.bytes.formattedBytes)
                        .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(CleanupFormat.items(result.entries.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 12) {
                if result.isTrash {
                    Button("Esvaziar Lixeira", systemImage: "trash", action: emptyTrash)
                        .buttonStyle(.tinted(Brand.red))
                } else {
                    Button {
                        model.toggleCategory(result.id)
                    } label: {
                        HStack(spacing: 7) {
                            TriStateCheckbox(state: model.checkState(result.id), tint: tint) {
                                model.toggleCategory(result.id)
                            }
                            .accessibilityHidden(true)
                            Text("Marcar todos")
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Marcar todos de \(result.category.title)")
                }
                if result.runningCount > 0, !result.isTrash {
                    Label("Itens em uso ou de apps abertos começam desmarcados", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Brand.orange)
                        .lineLimit(1)
                }
                Spacer()
                Picker("Ordenar por", selection: $model.sortOrder) {
                    ForEach(CleanupModel.SortOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background {
            LinearGradient(colors: [tint.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
        }
    }

    private func list(_ result: CleanupCategoryResult) -> some View {
        let tint = CleanupStyle.tint(result.id)
        let isTrash = result.isTrash
        let showsDate = result.id == .installers || result.id == .iosBackups || result.id == .developer
        return List(model.visibleEntries, selection: $highlighted) { entry in
            CleanupEntryRow(entry: entry, isChecked: model.isSelected(entry), showsCheckbox: !isTrash,
                            showsDate: showsDate, tint: tint) {
                model.toggle(entry)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: URL.self) { urls in
            menu(for: urls, isTrash: isTrash)
        } primaryAction: { urls in
            Reveal.inFinder(Array(urls))
        }
        .onKeyPress(.space) {
            guard !isTrash, !highlighted.isEmpty else { return .ignored }
            model.toggle(highlighted)
            return .handled
        }
    }

    @ViewBuilder
    private func menu(for urls: Set<URL>, isTrash: Bool) -> some View {
        if urls.count == 1, let url = urls.first {
            if !isTrash, let entry = model.visibleEntries.first(where: { $0.url == url }) {
                Button(model.isSelected(entry) ? "Desmarcar" : "Marcar") { model.toggle(entry) }
                Divider()
            }
            FileContextMenu(url: url, onIgnore: isTrash ? nil : { ignore(url) })
        } else if urls.count > 1 {
            if !isTrash {
                Button("Marcar \(urls.count) itens") { model.setSelected(urls, true) }
                Button("Desmarcar \(urls.count) itens") { model.setSelected(urls, false) }
                Divider()
            }
            Button("Quick Look") { Reveal.quickLook(Array(urls)) }
            Button("Mostrar no Finder") { Reveal.inFinder(Array(urls)) }
        }
    }

    private func ignore(_ url: URL) {
        withAnimation(Motion.standard(reduceMotion)) { model.ignore(url) }
        app.showToast("\(url.lastPathComponent) não aparece mais nas varreduras", symbol: "eye.slash")
    }

    private func emptyTrash() {
        let items = model.trashItems
        guard !items.isEmpty else { return }
        let model = self.model
        let animation = Motion.standard(reduceMotion)
        app.requestRemoval(items, source: Feature.cleanup.title, title: "Esvaziar a Lixeira?", forcedMode: .permanent,
                           note: "\(CleanupFormat.items(items.count)) · \(model.trashBytes.formattedBytes) serão apagados de vez.") { report in
            withAnimation(animation) { model.didRemove(report) }
        }
    }
}

private struct CleanupEntryRow: View {
    let entry: CleanupEntry
    let isChecked: Bool
    let showsCheckbox: Bool
    let showsDate: Bool
    let tint: Color
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsCheckbox {
                TriStateCheckbox(state: isChecked ? .on : .off, tint: tint, action: toggle)
                    .accessibilityLabel(isChecked ? "Desmarcar \(entry.label)" : "Marcar \(entry.label)")
            }
            FileIcon(url: entry.appURL ?? entry.url, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.label)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if entry.isAppRunning {
                        CleanupTag(text: "App aberto", tint: Brand.orange)
                            .help("Feche o app antes de limpar para não atrapalhar o que ele está fazendo")
                    } else if entry.isActive {
                        CleanupTag(text: "Em uso", tint: Brand.orange)
                            .help("Algo aqui foi gravado há poucos minutos")
                    }
                }
                Text(CleanupFormat.abbreviated(entry.url.path))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = entry.note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showsDate, let date = entry.lastModified {
                Text(date, format: CleanupFormat.relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            SizeText(bytes: entry.size)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .help(entry.url.path)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Peças

private struct CleanupSymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}

private struct CleanupTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .fixedSize()
    }
}

private enum CleanupStyle {
    static func tint(_ id: CleanupCategoryID) -> Color {
        switch id {
        case .appCaches: Brand.teal
        case .containerCaches: Color.indigo
        case .browsers: Color.blue
        case .developer: Brand.orange
        case .logs: Color.gray
        case .mailAttachments: Color.cyan
        case .savedState: Brand.violet
        case .installers: Brand.green
        case .iosBackups: Brand.magenta
        case .trash: Brand.red
        }
    }
}

private enum CleanupFormat {
    static let home = Paths.home.path

    /// "/Users/ana/Library/Caches/x" → "~/Library/Caches/x".
    static func abbreviated(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "pt_BR")))
    }

    static func items(_ count: Int) -> String {
        "\(number(count)) \(count == 1 ? "item" : "itens")"
    }

    static let relative = Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: "pt_BR"))
}
