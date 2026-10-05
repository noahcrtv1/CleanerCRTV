import CleanerCore
import SwiftUI

/// Resultados: grupos à esquerda, cópias do grupo em foco à direita, ação no rodapé.
struct DuplicateResultsView: View {
    let onRemove: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let duplicates = model.duplicates
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DuplicateGroupList()
                    .frame(width: 330)
                Divider()
                Group {
                    if let group = duplicates.focusedGroup {
                        DuplicateGroupDetail(group: group)
                            .id(group.id)
                    } else {
                        ContentUnavailableView("Escolha um grupo", systemImage: "square.on.square",
                                               description: Text("As cópias do grupo aparecem aqui."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ActionBar(summary: selectionSummary,
                      buttonTitle: "Remover cópias…",
                      enabled: duplicates.selectedCount > 0 && !duplicates.isPreparingRemoval) {
                totals
            } action: {
                onRemove()
            }
        }
    }

    private var selectionSummary: String {
        let duplicates = model.duplicates
        let count = duplicates.selectedCount
        guard count > 0 else { return "Nenhuma cópia marcada" }
        return "\(count) \(count == 1 ? "cópia selecionada" : "cópias selecionadas") · \(duplicates.selectedBytes.formattedBytes)"
    }

    private var totals: some View {
        let duplicates = model.duplicates
        let groups = duplicates.groups.count
        return HStack(spacing: 6) {
            Image(systemName: "square.on.square")
                .foregroundStyle(Feature.duplicates.tint)
            Text("\(groups) \(groups == 1 ? "grupo" : "grupos") · \(duplicates.totalReclaimable.formattedBytes) em cópias extras")
                .monospacedDigit()
            if let stats = duplicates.stats, stats.skippedCloud + stats.skippedUnreadable > 0 {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.tertiary)
                    .help(skippedHelp(stats))
                    .accessibilityLabel(skippedHelp(stats))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func skippedHelp(_ stats: DuplicateScanStats) -> String {
        var parts: [String] = []
        if stats.skippedCloud > 0 { parts.append("\(stats.skippedCloud) no iCloud sem baixar (não foram lidos)") }
        if stats.skippedUnreadable > 0 { parts.append("\(stats.skippedUnreadable) sem permissão de leitura ou alterados durante a busca") }
        return "Ficaram de fora: " + parts.joined(separator: "; ")
    }
}

// MARK: - Lista de grupos

struct DuplicateGroupList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var duplicates = model.duplicates
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filtrar por nome", text: $duplicates.searchText)
                        .textFieldStyle(.plain)
                    if !duplicates.searchText.isEmpty {
                        Button {
                            duplicates.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Limpar filtro")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Menu {
                    Picker("Ordenar por", selection: $duplicates.sortOrder) {
                        ForEach(DuplicateSortOrder.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Tipo", selection: $duplicates.kindFilter) {
                        Text("Todos os tipos").tag(DuplicateKind?.none)
                        ForEach(duplicates.availableKinds, id: \.self) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(DuplicateKind?.some(kind))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: duplicates.kindFilter == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(duplicates.kindFilter == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Feature.duplicates.tint))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Ordenar e filtrar")
                .accessibilityLabel("Ordenar e filtrar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: $duplicates.focusedGroupID) {
                Section {
                    ForEach(duplicates.visibleGroups) { group in
                        DuplicateGroupRow(group: group, state: duplicates.checkState(group)) {
                            duplicates.toggleGroup(group)
                        }
                        .contextMenu { groupMenu(group) }
                    }
                } header: {
                    Text("\(duplicates.visibleGroups.count) \(duplicates.visibleGroups.count == 1 ? "grupo" : "grupos") · \(duplicates.sortOrder.title.lowercased())")
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onKeyPress(.space) {
                guard let group = duplicates.focusedGroup else { return .ignored }
                duplicates.toggleGroup(group)
                return .handled
            }
            .overlay {
                if duplicates.visibleGroups.isEmpty {
                    ContentUnavailableView("Nada com esse filtro", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Mude o filtro ou o texto da busca."))
                }
            }
        }
    }

    @ViewBuilder private func groupMenu(_ group: DuplicateGroup) -> some View {
        let duplicates = model.duplicates
        if let preview = group.previewFile {
            Button("Quick Look") { Reveal.quickLook([preview.url]) }
        }
        Button("Mostrar cópias no Finder") { Reveal.inFinder(group.files.map(\.url)) }
        Divider()
        if duplicates.selectedCount(in: group) > 0 {
            Button("Desmarcar este grupo") { duplicates.toggleGroup(group) }
        } else {
            Button("Marcar cópias extras (manter a mais antiga)") { duplicates.toggleGroup(group) }
        }
    }
}

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let state: TriStateCheckbox.CheckState
    let onToggle: () -> Void

    var body: some View {
        let preview = group.previewFile?.url ?? URL(fileURLWithPath: "/")
        HStack(spacing: 10) {
            TriStateCheckbox(state: state, tint: Feature.duplicates.tint, action: onToggle)
                .accessibilityLabel(state == .off
                                    ? "Marcar cópias extras de \(group.displayName)"
                                    : "Desmarcar cópias de \(group.displayName)")
            DuplicateThumbnailView(url: preview, size: 34, loadsContent: DuplicateKind.hasContentThumbnail(preview))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text("\(group.files.count) cópias · \(group.size.formattedBytes) cada")
                        .lineLimit(1)
                    if group.isCloneGroup {
                        DuplicateTagView(text: "clones", tint: Brand.teal)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(group.isCloneGroup ? "—" : group.reclaimable.formattedBytes)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(group.isCloneGroup ? .secondary : .primary)
                .help(group.isCloneGroup ? "Clones APFS: remover não libera espaço" : "Espaço ocupado pelas cópias extras")
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detalhe do grupo

struct DuplicateGroupDetail: View {
    let group: DuplicateGroup

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let duplicates = model.duplicates
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if group.isCloneGroup { cloneBanner }
                copies
            }
            .padding(24)
        }
        .overlay(alignment: .top) {
            if let hint = duplicates.hint {
                Label(hint, systemImage: "info.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.standard(reduceMotion), value: duplicates.hint)
    }

    private var header: some View {
        let duplicates = model.duplicates
        let preview = group.previewFile?.url ?? URL(fileURLWithPath: "/")
        let marked = duplicates.selectedCount(in: group)
        return HStack(alignment: .center, spacing: 20) {
            DuplicateThumbnailView(url: preview, size: 148, cornerRadius: 10, fit: true)
                .frame(width: 168, height: 168)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary.opacity(0.4)))
                .onTapGesture(count: 2) { Reveal.quickLook([preview]) }
                .help("Clique duas vezes para o Quick Look")
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.displayName)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("\(group.files.count) cópias idênticas · \(group.size.formattedBytes) cada")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 24) {
                    StatTile(title: "Desperdício", value: group.isCloneGroup ? "—" : group.reclaimable.formattedBytes,
                             tint: Feature.duplicates.tint, symbol: "square.on.square")
                    StatTile(title: "Marcadas", value: "\(marked) de \(group.files.count)",
                             tint: marked > 0 ? Feature.duplicates.tint : .secondary, symbol: "checkmark.circle")
                }
                HStack(spacing: 8) {
                    Button {
                        Reveal.quickLook([preview])
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    Button {
                        Reveal.open(preview)
                    } label: {
                        Label("Abrir", systemImage: "arrow.up.forward.app")
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    private var cloneBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.on.square.dashed")
                .font(.title3)
                .foregroundStyle(Brand.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clones APFS — remover não libera espaço")
                    .fontWeight(.semibold)
                Text("Estas cópias dividem os mesmos blocos no disco. Apagar uma só deixa as pastas mais arrumadas.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var copies: some View {
        let duplicates = model.duplicates
        // "mais antigo" só faz sentido quando as datas diferem.
        let dates = Set(group.files.compactMap(\.originDate))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cópias").font(.headline)
                Spacer()
                Text("Marque as que quer remover. Uma sempre fica.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GlassCard(padding: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider().padding(.leading, 66) }
                        DuplicateCopyRow(
                            file: file,
                            isSelected: duplicates.isSelected(file),
                            tags: tags(for: file, isOldest: index == 0 && dates.count > 1),
                            onToggle: { duplicates.toggle(file, in: group) },
                            onKeepOnly: { duplicates.keepOnly(file, in: group) },
                            onPreferFolder: { duplicates.autoSelect(.inFolder(file.folder)) },
                            onIgnoreFolder: {
                                duplicates.ignoreFolder(file.folder)
                                model.showToast("“\(DuplicateRoots.displayName(file.folder))” agora fica fora das varreduras",
                                                symbol: "eye.slash.fill")
                            }
                        )
                    }
                }
            }
        }
    }

    private func tags(for file: DuplicateFile, isOldest: Bool) -> [DuplicateTagView] {
        var tags: [DuplicateTagView] = []
        if isOldest { tags.append(DuplicateTagView(text: "mais antigo", tint: Brand.green)) }
        if !group.isCloneGroup, group.isClone(file) { tags.append(DuplicateTagView(text: "clone", tint: Brand.teal)) }
        if file.linkCount > 1 { tags.append(DuplicateTagView(text: "link físico", tint: Brand.violet)) }
        return tags
    }
}

struct DuplicateCopyRow: View {
    let file: DuplicateFile
    let isSelected: Bool
    let tags: [DuplicateTagView]
    let onToggle: () -> Void
    let onKeepOnly: () -> Void
    let onPreferFolder: () -> Void
    let onIgnoreFolder: () -> Void

    var body: some View {
        let folderName = DuplicateRoots.displayName(file.folder)
        HStack(spacing: 12) {
            TriStateCheckbox(state: isSelected ? .on : .off, tint: Feature.duplicates.tint, action: onToggle)
                .accessibilityLabel(isSelected ? "Manter \(file.name)" : "Marcar \(file.name) para remover")
            FileIcon(url: file.url, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(tags, id: \.text) { $0 }
                }
                Text(duplicateTildePath(file.folder.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
            }
            Spacer(minLength: 8)
            if let modified = file.modified {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(modified, format: .dateTime.day().month(.abbreviated).year())
                    Text("modificado")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            HStack(spacing: 2) {
                iconButton("eye", label: "Quick Look") { Reveal.quickLook([file.url]) }
                iconButton("folder", label: "Mostrar no Finder") { Reveal.inFinder(file.url) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Feature.duplicates.tint.opacity(0.07) : .clear)
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .contextMenu {
            FileContextMenu(url: file.url)
            Divider()
            Button("Manter só esta", action: onKeepOnly)
            Button("Preferir “\(folderName)” em todos os grupos", action: onPreferFolder)
            Divider()
            Button("Ignorar sempre “\(folderName)”", action: onIgnoreFolder)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Etiqueta pequena colorida ("clone", "mais antigo"…).
struct DuplicateTagView: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.13), in: Capsule())
            .fixedSize()
    }
}
