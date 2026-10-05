import AppKit
import CleanerCore
import SwiftUI

struct LargeOldView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosingFolder = false

    private var model: LargeOldModel { app.largeOld }

    private enum Phase { case intro, scanning, results }

    private var phase: Phase {
        if model.isScanning { return .scanning }
        return model.scannedRoot == nil ? .intro : .results
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .largeOld, subtitle: subtitle) {
                HStack(spacing: 10) {
                    LargeOldRootMenu(choosingFolder: $choosingFolder, choose: choose)
                    if model.scannedRoot != nil {
                        Button {
                            model.startScan()
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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.standard(reduceMotion), value: phase)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { choose(.folder(url)) }
        }
        .task { await model.refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await model.refreshVolumes() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await model.refreshVolumes() }
        }
        .onChange(of: model.issue) { _, issue in
            guard let issue else { return }
            app.alert = issue
            model.issue = nil
        }
    }

    private var subtitle: String? {
        guard phase == .results, let root = model.scannedRoot else { return nil }
        let count = model.progress.filesVisited
        return count > 0 ? "\(root.title) · \(count.formatted()) arquivos analisados" : root.title
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .intro:
            ScanHero(symbol: Feature.largeOld.symbol, tint: Feature.largeOld.tint,
                     title: "Ache o que pesa e ficou esquecido",
                     message: "Procuramos \(model.root.inPhrase) arquivos enormes e os que você não abre há meses. Nada sai sem a sua confirmação.") {
                model.startScan()
            }
            .transition(.opacity)
        case .scanning:
            ScanningView(title: "Procurando arquivos grandes…",
                         detail: model.progress.currentFolder.isEmpty ? nil : LargeOldFormat.displayPath(model.progress.currentFolder),
                         counter: scanCounter,
                         onCancel: { model.cancel() })
                .transition(.opacity)
        case .results:
            LargeOldResults(remove: remove)
                .transition(.opacity)
        }
    }

    private var scanCounter: String {
        let p = model.progress
        let files = "\(p.filesVisited.formatted()) arquivos analisados"
        guard p.found > 0 else { return files }
        return "\(files) · \(p.found.formatted()) grandes · \(p.bytesFound.formattedBytes)"
    }

    private func choose(_ root: LargeOldRoot) {
        if let problem = model.choose(root) { app.alert = problem }
    }

    private func remove() {
        let items = model.removalItems()
        guard !items.isEmpty else { return }
        let hidden = model.hiddenCheckedCount
        let note = hidden > 0
            ? "\(hidden) \(hidden == 1 ? "item marcado está escondido" : "itens marcados estão escondidos") pelos filtros e também \(hidden == 1 ? "sai" : "saem")."
            : "São arquivos seus, não caches: confira a lista antes de continuar."
        let model = model
        app.requestRemoval(items, source: Feature.largeOld.title, note: note) { report in
            model.didRemove(report)
        }
    }
}

// MARK: - Raiz

private struct LargeOldRootMenu: View {
    @Binding var choosingFolder: Bool
    let choose: (LargeOldRoot) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.largeOld
        Menu {
            Picker("Onde procurar", selection: Binding(get: { model.root }, set: { choose($0) })) {
                Label("Pasta pessoal", systemImage: "house").tag(LargeOldRoot.home)
                if case .folder = model.root {
                    Label(model.root.title, systemImage: "folder").tag(model.root)
                }
                ForEach(model.volumes) { volume in
                    Label(volume.name, systemImage: volume.isNetwork ? "network" : "externaldrive")
                        .tag(LargeOldRoot.volume(volume))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Escolher…") { choosingFolder = true }
        } label: {
            Label(model.root.title, systemImage: model.root.symbol)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Onde procurar")
    }
}

// MARK: - Resultados

private struct LargeOldResults: View {
    let remove: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.largeOld
        VStack(spacing: 0) {
            LargeOldFilterBar()
            Divider()
            Group {
                if model.visible.isEmpty {
                    LargeOldEmptyState()
                } else {
                    LargeOldTable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ActionBar(summary: selectionSummary, buttonTitle: "Remover…", enabled: !model.checked.isEmpty, leading: {
                HStack(spacing: 10) {
                    TriStateCheckbox(state: model.visibleCheckState, tint: Feature.largeOld.tint) {
                        model.toggleAllVisible()
                    }
                    .disabled(model.visible.isEmpty)
                    .accessibilityLabel(model.visibleCheckState == .on ? "Desmarcar todos os visíveis" : "Marcar todos os visíveis")
                    Text("\(model.visible.count.formatted()) \(model.visible.count == 1 ? "arquivo" : "arquivos") · \(model.visibleBytes.formattedBytes)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }, action: remove)
        }
    }

    private var selectionSummary: String {
        let model = app.largeOld
        let n = model.checked.count
        guard n > 0 else { return "Nenhum selecionado" }
        return "\(n.formatted()) \(n == 1 ? "selecionado" : "selecionados") · \(model.checkedBytes.formattedBytes)"
    }
}

private struct LargeOldEmptyState: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.largeOld
        if model.hasActiveFilters {
            ContentUnavailableView {
                Label("Nada com esses filtros", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nenhum arquivo de \(model.threshold.title) ou mais combina com o que você escolheu.")
            } actions: {
                Button("Limpar filtros") { model.clearFilters() }
            }
        } else {
            ContentUnavailableView {
                Label("Nenhum arquivo grande", systemImage: "checkmark.seal")
            } description: {
                Text("Não há arquivos de \(model.threshold.title) ou mais \((model.scannedRoot ?? .home).inPhrase). Tudo leve por aqui.")
            } actions: {
                if model.threshold != .mb10 {
                    Button("Procurar a partir de 10 MB") { model.threshold = .mb10 }
                }
            }
        }
    }
}

// MARK: - Filtros

private struct LargeOldFilterBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.largeOld
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Picker("Tamanho mínimo", selection: $model.threshold) {
                    ForEach(LargeOldSizeThreshold.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("Sem abrir há", selection: $model.age) {
                    ForEach(LargeOldAge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 8)
                LargeOldSearchField(text: $model.searchText)
            }
            .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        LargeOldKindChip(title: "Todos", symbol: "square.grid.2x2", tint: Feature.largeOld.tint,
                                         total: allTotal(model), isOn: model.kinds.isEmpty) {
                            model.kinds = []
                        }
                        ForEach(LargeOldKind.allCases) { kind in
                            LargeOldKindChip(title: kind.title, symbol: kind.symbol, tint: kind.tint,
                                             total: model.kindTotals[kind] ?? LargeOldKindTotal(),
                                             isOn: model.kinds.contains(kind)) {
                                model.toggleKind(kind)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .contentMargins(.horizontal, 28, for: .scrollContent)
        }
        .padding(.bottom, 12)
    }

    private func allTotal(_ model: LargeOldModel) -> LargeOldKindTotal {
        model.kindTotals.values.reduce(into: LargeOldKindTotal()) {
            $0.count += $1.count
            $0.bytes += $1.bytes
        }
    }
}

private struct LargeOldKindChip: View {
    let title: String
    let symbol: String
    let tint: Color
    let total: LargeOldKindTotal
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.medium)
                Text(title)
                    .fontWeight(.medium)
                Text(total.count > 0 ? "\(total.count.formatted()) · \(total.bytes.formattedBytes)" : "0")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .glassEffect(isOn ? .regular.tint(tint.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
        .opacity(total.count == 0 && !isOn ? 0.55 : 1)
        .accessibilityLabel("\(title), \(total.count) arquivos, \(total.bytes.formattedBytes)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct LargeOldSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar pelo nome", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 220)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Tabela

private struct LargeOldTable: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.largeOld
        Table(model.visible, selection: $model.tableSelection, sortOrder: $model.sortOrder) {
            TableColumn("") { file in
                LargeOldCheckCell(file: file)
            }
            .width(22)
            TableColumn("Nome", value: \.name) { file in
                HStack(spacing: 8) {
                    FileIcon(url: file.url, size: 18)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(file.url.path)
            }
            .width(min: 180, ideal: 300)
            TableColumn("Tipo", value: \.kindTitle) { file in
                Text(file.kindTitle).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Tamanho", value: \.size) { file in
                Text(file.size.formattedBytes)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Última abertura", value: \.lastUsed) { file in
                Text(LargeOldFormat.relative(file.lastUsed))
                    .foregroundStyle(.secondary)
                    .help(LargeOldFormat.dateHelp(file))
            }
            .width(min: 90, ideal: 120)
            TableColumn("Local", value: \.folder) { file in
                Text(LargeOldFormat.displayPath(file.folder))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.folder)
            }
            .width(min: 120, ideal: 260)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: URL.self) { urls in
            LargeOldRowMenu(urls: urls)
        } primaryAction: { urls in
            quickLook(urls)
        }
        .onKeyPress(.space) {
            guard !model.tableSelection.isEmpty else { return .ignored }
            quickLook(model.tableSelection)
            return .handled
        }
    }

    private func quickLook(_ urls: Set<URL>) {
        // Na ordem da tabela, para as setas do Quick Look andarem como a lista.
        let ordered = app.largeOld.visible.lazy.map(\.url).filter { urls.contains($0) }
        Reveal.quickLook(Array(ordered))
    }
}

private struct LargeOldCheckCell: View {
    let file: LargeOldFile
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.largeOld
        TriStateCheckbox(state: model.isChecked(file) ? .on : .off, tint: Feature.largeOld.tint) {
            model.toggle(file)
        }
        .accessibilityLabel("Marcar \(file.name) para remover")
    }
}

private struct LargeOldRowMenu: View {
    let urls: Set<URL>
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.largeOld
        let rows = model.visible.filter { urls.contains($0.url) }
        if rows.count == 1, let file = rows.first {
            FileContextMenu(url: file.url)
            Divider()
            Button(model.isChecked(file) ? "Desmarcar" : "Marcar para remover") { model.toggle(file) }
            Divider()
            Button("Ignorar sempre este arquivo") { model.ignore(file.url) }
            let folder = file.url.deletingLastPathComponent()
            if LargeOldFormat.canIgnoreFolder(folder) {
                Button("Ignorar sempre a pasta “\(folder.lastPathComponent)”") { model.ignore(folder) }
            }
        } else if !rows.isEmpty {
            let list = rows.map(\.url)
            Button("Quick Look") { Reveal.quickLook(list) }
            Button("Mostrar no Finder") { Reveal.inFinder(list) }
            Divider()
            Button("Marcar \(rows.count) para remover") { model.setChecked(urls, true) }
            Button("Desmarcar \(rows.count)") { model.setChecked(urls, false) }
        }
    }
}

// MARK: - Apoio

@MainActor
private enum LargeOldFormat {
    static let home = Paths.home.standardizedFileURL.path

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "há 2 anos", "ontem"…
    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: min(date, Date()), relativeTo: Date())
    }

    static func dateHelp(_ file: LargeOldFile) -> String {
        let date = file.lastUsed.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "pt_BR")))
        return file.lastUsedFromSpotlight ? "Aberto em \(date)" : "Último uso conhecido (modificação ou acesso): \(date)"
    }

    /// Caminho com "~" no lugar da pasta pessoal.
    static func displayPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Ignorar a pasta pessoal ou a raiz de um disco esconderia tudo de todas as varreduras.
    static func canIgnoreFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let components = path.split(separator: "/")
        if path == home || path == "/" { return false }
        if components.count <= 2, components.first == "Volumes" { return false }
        return true
    }
}

private extension LargeOldKind {
    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .archive: "archivebox"
        case .diskImage: "opticaldiscdrive"
        case .document: "doc.richtext"
        case .other: "doc"
        }
    }

    var tint: Color {
        switch self {
        case .video: Brand.magenta
        case .audio: Brand.violet
        case .image: Brand.teal
        case .archive: Brand.orange
        case .diskImage: Brand.red
        case .document: Brand.green
        case .other: .gray
        }
    }
}
