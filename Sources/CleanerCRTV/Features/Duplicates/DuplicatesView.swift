import AppKit
import CleanerCore
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var duplicates: DuplicatesModel { model.duplicates }

    private enum Stage: Hashable { case idle, scanning, empty, results }

    private var stage: Stage {
        if duplicates.isScanning { return .scanning }
        guard duplicates.hasResults else { return .idle }
        return duplicates.groups.isEmpty ? .empty : .results
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .duplicates) { headerActions }
            DuplicateOptionsBar(onAddFolders: addFolders)
                .disabled(duplicates.isScanning)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(stage)
                .transition(.opacity)
        }
        .animation(Motion.standard(reduceMotion), value: stage)
    }

    // MARK: - Cabeçalho

    @ViewBuilder private var headerActions: some View {
        if stage == .results || stage == .empty {
            HStack(spacing: 10) {
                if stage == .results {
                    DuplicateAutoSelectMenu(onPickFolder: pickPreferredFolder)
                }
                if duplicates.settingsChanged {
                    Button("Escanear de novo", action: startScan)
                        .buttonStyle(.gradient)
                        .help("As pastas ou o tamanho mínimo mudaram: escaneie de novo para aplicar")
                } else {
                    Button("Escanear de novo", action: startScan)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
    }

    // MARK: - Conteúdo

    @ViewBuilder private var content: some View {
        switch stage {
        case .scanning:
            ScanningView(title: duplicates.progress.phase.title,
                         detail: duplicates.progress.currentPath.map(duplicateTildePath),
                         progress: duplicates.progress.fraction,
                         counter: scanCounter,
                         onCancel: duplicates.cancel)
        case .idle:
            ScanHero(symbol: Feature.duplicates.symbol, tint: Feature.duplicates.tint,
                     title: "Encontre arquivos repetidos", message: heroMessage, action: startScan)
                .disabled(duplicates.roots.isEmpty)
        case .empty:
            ContentUnavailableView {
                Label("Nenhum duplicado", systemImage: "checkmark.seal")
            } description: {
                Text("Nenhum arquivo de \((duplicates.stats?.minSize ?? duplicates.minSize).label) ou mais aparece repetido nas pastas escolhidas. Tudo em ordem!"
                     + (skippedNote.map { "\n" + $0 } ?? ""))
            } actions: {
                Button("Escanear de novo", action: startScan)
            }
        case .results:
            DuplicateResultsView(onRemove: removeSelected)
        }
    }

    private var heroMessage: String {
        let roots = duplicates.roots
        guard !roots.isEmpty else { return "Adicione pelo menos uma pasta acima para começar." }
        let places = roots.count <= 4
            ? roots.map(DuplicateRoots.displayName).formatted(.list(type: .and))
            : "\(roots.count) pastas"
        return "Procuramos em \(places) arquivos de \(duplicates.minSize.label) ou mais e conferimos o conteúdo byte a byte. Nada sai sem a sua confirmação."
    }

    private var scanCounter: String {
        let p = duplicates.progress
        switch p.phase {
        case .collecting:
            return "\(p.filesVisited.formatted()) arquivos vistos · \(p.candidates.formatted()) com \(duplicates.minSize.label) ou mais"
        case .comparingEdges, .comparingContents:
            return "\(p.hashed.formatted()) de \(p.toHash.formatted()) arquivos · \(p.bytesHashed.formattedBytes) de \(p.bytesToHash.formattedBytes)"
        case .finishing:
            return "\(p.candidates.formatted()) arquivos comparados"
        }
    }

    private var skippedNote: String? {
        guard let stats = duplicates.stats, stats.skippedCloud > 0 else { return nil }
        return "\(stats.skippedCloud) \(stats.skippedCloud == 1 ? "item do iCloud não baixado ficou" : "itens do iCloud não baixados ficaram") de fora."
    }

    // MARK: - Ações

    private func startScan() {
        Task { await duplicates.scan() }
    }

    private func removeSelected() {
        Task {
            let plan = await duplicates.prepareRemoval()
            guard !plan.items.isEmpty else {
                model.showToast("Nenhuma cópia pôde ser removida: os arquivos mudaram desde a varredura. Escaneie de novo.",
                                symbol: "exclamationmark.triangle.fill", isError: true)
                return
            }
            let count = plan.items.count
            var notes = ["Uma cópia de cada arquivo continua no lugar."]
            if plan.skipped > 0 {
                notes.append("\(plan.skipped) \(plan.skipped == 1 ? "cópia mudou" : "cópias mudaram") desde a varredura e \(plan.skipped == 1 ? "ficou" : "ficaram") de fora.")
            }
            let noSpace = plan.items.lazy.filter { $0.size == 0 }.count
            if noSpace > 0 {
                notes.append("\(noSpace) não \(noSpace == 1 ? "libera" : "liberam") espaço (clones APFS ou links físicos).")
            }
            model.requestRemoval(plan.items, source: Feature.duplicates.title,
                                 title: "Remover \(count) \(count == 1 ? "cópia" : "cópias")?",
                                 note: notes.joined(separator: " ")) { [duplicates] report in
                duplicates.applyRemoval(report)
            }
        }
    }

    private func addFolders() {
        Task {
            guard let urls = await chooseFolders(multiple: true, prompt: "Adicionar",
                                                 message: "Escolha pastas para procurar arquivos repetidos") else { return }
            let problems = duplicates.addRoots(urls)
            if let first = problems.first {
                model.showToast(problems.count == 1 ? first : "\(first) (e mais \(problems.count - 1))",
                                symbol: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }

    private func pickPreferredFolder() {
        Task {
            guard let url = await chooseFolders(multiple: false, prompt: "Manter daqui",
                                                message: "Em cada grupo, fica a cópia que estiver nesta pasta")?.first else { return }
            duplicates.autoSelect(.inFolder(url))
        }
    }

    private func chooseFolders(multiple: Bool, prompt: String, message: String) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = Paths.home
        let response = if let window = model.mainWindow {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        return response == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }
}

// MARK: - Barra de opções

/// Pastas da busca (fichas), "Adicionar pasta…" e tamanho mínimo.
struct DuplicateOptionsBar: View {
    let onAddFolders: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var duplicates = model.duplicates
        HStack(spacing: 12) {
            Text("Procurar em")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(duplicates.roots, id: \.self) { root in
                            DuplicateRootChip(url: root) { duplicates.removeRoot(root) }
                        }
                        if duplicates.roots.isEmpty {
                            Text("Nenhuma pasta")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Button(action: onAddFolders) {
                Label("Adicionar pasta…", systemImage: "plus")
            }
            if !duplicates.rootsAreDefault {
                Button {
                    duplicates.restoreDefaultRoots()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Voltar às pastas padrão")
                .accessibilityLabel("Voltar às pastas padrão")
            }
            Divider().frame(height: 18)
            Picker("Mínimo", selection: $duplicates.minSize) {
                ForEach(DuplicateMinSize.allCases) { size in
                    Text("\(size.label) ou mais").tag(size)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }
}

/// Ficha de uma pasta da busca.
struct DuplicateRootChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        let name = DuplicateRoots.displayName(url)
        HStack(spacing: 6) {
            FileIcon(url: url, size: 16)
            Text(name)
                .font(.callout)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .help("Tirar da busca")
            .accessibilityLabel("Tirar “\(name)” da busca")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .help(duplicateTildePath(url.path))
        .contextMenu {
            Button("Mostrar no Finder") { Reveal.inFinder(url) }
            Button("Tirar da busca", action: onRemove)
        }
    }
}

/// Menu "Selecionar automaticamente": o clique aplica a regra padrão (manter o mais antigo).
struct DuplicateAutoSelectMenu: View {
    let onPickFolder: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let duplicates = model.duplicates
        Menu {
            Section(duplicates.isFiltered
                    ? "Vale para os \(duplicates.visibleGroups.count) grupos visíveis"
                    : "Fica uma cópia de cada grupo") {
                Button("Manter o mais antigo") { duplicates.autoSelect(.oldest) }
                Button("Manter o mais novo") { duplicates.autoSelect(.newest) }
                Menu("Manter o que está em") {
                    ForEach(duplicates.roots, id: \.self) { root in
                        Button(DuplicateRoots.displayName(root)) { duplicates.autoSelect(.inFolder(root)) }
                    }
                    if !duplicates.roots.isEmpty { Divider() }
                    Button("Escolher pasta…", action: onPickFolder)
                }
            }
            Divider()
            Button("Desmarcar tudo") { duplicates.deselectAll() }
                .disabled(duplicates.selectedCount == 0)
        } label: {
            Label("Selecionar automaticamente", systemImage: "checklist")
        } primaryAction: {
            duplicates.autoSelect(.oldest)
        }
        .fixedSize()
        .controlSize(.large)
        .help("Marca as cópias extras e mantém a mais antiga de cada grupo. Abra o menu para outras regras.")
    }
}

/// Caminho com "~" no lugar da pasta pessoal.
func duplicateTildePath(_ path: String) -> String {
    let home = Paths.home.path
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
