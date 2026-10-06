import CleanerCore
import SwiftUI

/// Escaneamento inteligente: roda os módulos leves juntos e resume o que dá para liberar.
@Observable
@MainActor
final class DashboardModel {
    enum Phase { case idle, scanning, done }

    /// Módulos do escaneamento inteligente. Duplicados e Mapa do disco ficam de fora (leem o disco inteiro).
    static let smartFeatures: [Feature] = [.cleanup, .largeOld, .uninstaller, .optimize]

    var phase: Phase = .idle
    var running: Set<Feature> = []
    var lastScan: Date?
    var trashBytes: Int64 = 0
    var volume = VolumeUsage.startup()

    @ObservationIgnored private var task: Task<Void, Never>?

    func scan(_ app: AppModel) {
        task?.cancel()
        phase = .scanning
        running = Set(Self.smartFeatures)
        task = Task { [weak self] in
            await withTaskGroup(of: Feature.self) { group in
                for feature in Self.smartFeatures {
                    guard let scanner = app.scanner(for: feature) else { continue }
                    group.addTask { @MainActor in
                        await scanner.scan()
                        return feature
                    }
                }
                for await feature in group {
                    _ = withAnimation(Motion.standard) { self?.running.remove(feature) }
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.refreshTrash()
            self.volume = VolumeUsage.startup()
            self.lastScan = Date()
            withAnimation(Motion.standard) { self.phase = .done }
        }
    }

    func cancel(_ app: AppModel) {
        task?.cancel()
        Self.smartFeatures.forEach { app.scanner(for: $0)?.cancel() }
        running = []
        phase = lastScan == nil ? .idle : .done
    }

    func refreshTrash() async {
        trashBytes = await Task.detached(priority: .utility) { FileSizer.allocatedSize(of: Paths.trash) }.value
    }

    func trashItems() async -> [RemovalItem] {
        await Task.detached(priority: .userInitiated) {
            let contents = (try? FileManager.default.contentsOfDirectory(at: Paths.trash, includingPropertiesForKeys: nil)) ?? []
            return contents.map { RemovalItem(url: $0, size: FileSizer.allocatedSize(of: $0)) }
        }.value
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dashboard: DashboardModel { model.dashboard }

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .dashboard) {
                if let date = dashboard.lastScan, dashboard.phase == .done {
                    Text("Última varredura \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 22) {
                    DashboardHero(volume: dashboard.volume,
                                  reclaimable: model.cleanup.summary?.bytes ?? 0,
                                  phase: dashboard.phase) {
                        dashboard.scan(model)
                    } onCancel: {
                        dashboard.cancel(model)
                    }
                    if dashboard.phase == .scanning {
                        ScanProgressList(running: dashboard.running)
                            .transition(.opacity)
                    } else if dashboard.phase == .done {
                        ResultsGrid()
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        ShortcutGrid()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .animation(Motion.standard(reduceMotion), value: dashboard.phase)
            }
        }
        .task {
            dashboard.volume = VolumeUsage.startup()
            await dashboard.refreshTrash()
        }
    }
}

// MARK: - Topo

private struct DashboardHero: View {
    let volume: VolumeUsage
    let reclaimable: Int64
    let phase: DashboardModel.Phase
    let onScan: () -> Void
    let onCancel: () -> Void

    var body: some View {
        GlassCard(padding: 26) {
            HStack(spacing: 30) {
                DiskDonut(volume: volume, scanning: phase == .scanning)
                    .frame(width: 168, height: 168)
                VStack(alignment: .leading, spacing: 10) {
                    Text(phase == .done && reclaimable > 0 ? "Dá para liberar \(reclaimable.formattedBytes)" : "Escaneamento inteligente")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(phase == .done
                         ? "Revise cada parte abaixo. Por padrão tudo vai para a Lixeira."
                         : "Procura lixo do sistema, arquivos grandes e esquecidos, apps sem uso e itens de inicialização — tudo de uma vez.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        Label("\(volume.available.formattedBytes) livres", systemImage: "internaldrive")
                        if volume.purgeable > 1_000_000_000 {
                            Label("\(volume.purgeable.formattedBytes) liberáveis pelo macOS", systemImage: "arrow.3.trianglepath")
                                .help("Espaço purgeable: o macOS libera sozinho quando precisa (caches do iCloud, snapshots locais…).")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        if phase == .scanning {
                            Button("Parar", action: onCancel)
                                .keyboardShortcut(.cancelAction)
                        } else {
                            Button(phase == .done ? "Escanear de novo" : "Escanear", action: onScan)
                                .buttonStyle(.gradientLarge)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
    }
}

/// Rosca do disco: usado (gradiente), liberável pelo macOS (cinza) e livre.
private struct DiskDonut: View {
    let volume: VolumeUsage
    var scanning: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        let total = Double(max(volume.total, 1))
        let used = Double(volume.used) / total
        let purgeable = Double(volume.purgeable) / total
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 16)
            Circle()
                .trim(from: used, to: min(1, used + purgeable))
                .stroke(.gray.opacity(0.45), style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: used)
                .stroke(AngularGradient(colors: Brand.bands + [Brand.red], center: .center),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if scanning {
                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(-14)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
            }
            VStack(spacing: 2) {
                Text("\(Int((volume.usedFraction * 100).rounded()))%")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                Text("usado").font(.caption).foregroundStyle(.secondary)
                Text(volume.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.name): \(Int(volume.usedFraction * 100))% usado, \(volume.available.formattedBytes) livres")
    }
}

// MARK: - Varredura em andamento

private struct ScanProgressList: View {
    let running: Set<Feature>

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(DashboardModel.smartFeatures) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.symbol)
                            .foregroundStyle(feature.tint)
                            .frame(width: 22)
                        Text(feature.title)
                        Spacer()
                        if running.contains(feature) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Brand.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .font(.body.weight(.medium))
                }
            }
        }
    }
}

// MARK: - Resultados

private struct ResultsGrid: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            JunkCard()
            TrashCard()
            SummaryCard(feature: .largeOld, summary: model.largeOld.summary,
                        empty: "Nenhum arquivo grande esquecido")
            SummaryCard(feature: .uninstaller, summary: model.uninstaller.summary,
                        empty: "Todos os apps foram usados recentemente")
            SummaryCard(feature: .optimize, summary: model.optimize.summary,
                        empty: "Nada para revisar na inicialização", showBytes: false)
            DuplicatesCard()
        }
    }
}

/// Cartão-base: ícone, título, número grande, detalhe e ações.
private struct ResultCard<Actions: View>: View {
    let feature: Feature
    var title: String?
    let value: String
    var detail: String?
    var dimmed = false
    @ViewBuilder var actions: Actions

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(feature.tint.gradient))
                    Text(title ?? feature.title).font(.headline)
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(feature.tint))
                    .contentTransition(.numericText())
                Text(detail ?? " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                HStack(spacing: 10) { actions }
            }
        }
    }
}

private struct JunkCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanup = model.cleanup
        let items = cleanup.recommendedItems
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        ResultCard(feature: .cleanup,
                   value: bytes > 0 ? bytes.formattedBytes : "Tudo limpo",
                   detail: cleanup.summary.map { "\($0.count) itens encontrados · \(items.count) recomendados" },
                   dimmed: bytes == 0) {
            Button("Limpar") {
                model.requestRemoval(items, source: "Painel · \(Feature.cleanup.title)") { report in
                    cleanup.didRemove(report)
                }
            }
            .buttonStyle(.tinted(Feature.cleanup.tint))
            .disabled(items.isEmpty)
            Button("Revisar") { model.selection = .cleanup }
        }
    }
}

private struct TrashCard: View {
    @Environment(AppModel.self) private var model
    @State private var loading = false

    var body: some View {
        let bytes = model.dashboard.trashBytes
        ResultCard(feature: .cleanup, title: "Lixeira",
                   value: bytes > 0 ? bytes.formattedBytes : "Vazia",
                   detail: bytes > 0 ? "O espaço dos itens na Lixeira só volta quando ela é esvaziada." : nil,
                   dimmed: bytes == 0) {
            Button("Esvaziar…") {
                loading = true
                Task {
                    let items = await model.dashboard.trashItems()
                    loading = false
                    model.requestRemoval(items, source: "Lixeira", title: "Esvaziar a Lixeira?",
                                         forcedMode: .permanent) { _ in
                        Task { await model.dashboard.refreshTrash() }
                    }
                }
            }
            .buttonStyle(.tinted(Brand.red))
            .disabled(bytes == 0 || loading)
        }
    }
}

private struct SummaryCard: View {
    @Environment(AppModel.self) private var model
    let feature: Feature
    let summary: ScanSummary?
    let empty: String
    var showBytes = true

    var body: some View {
        let hasResult = (summary?.count ?? 0) > 0
        ResultCard(feature: feature,
                   title: summary?.title,
                   value: valueText,
                   detail: hasResult ? summary?.detail ?? countText : empty,
                   dimmed: !hasResult) {
            Button("Revisar") { model.selection = feature }
        }
    }

    private var countText: String? {
        guard let summary else { return nil }
        return showBytes ? "\(summary.count) \(summary.count == 1 ? "item" : "itens")" : nil
    }

    private var valueText: String {
        guard let summary, summary.count > 0 else { return "Nada" }
        if showBytes, summary.bytes > 0 { return summary.bytes.formattedBytes }
        return "\(summary.count)"
    }
}

private struct DuplicatesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let duplicates = model.duplicates
        if let summary = duplicates.summary {
            ResultCard(feature: .duplicates,
                       value: summary.bytes > 0 ? summary.bytes.formattedBytes : "Nenhum",
                       detail: summary.count > 0 ? "\(summary.count) grupos de cópias idênticas" : "Nenhuma cópia encontrada",
                       dimmed: summary.count == 0) {
                Button("Revisar") { model.selection = .duplicates }
            }
        } else {
            ResultCard(feature: .duplicates, value: "Não verificado",
                       detail: "Comparar arquivos byte a byte leva alguns minutos.", dimmed: true) {
                Button(duplicates.isScanning ? "Procurando…" : "Procurar duplicados") {
                    model.selection = .duplicates
                    Task { await duplicates.scan() }
                }
                .disabled(duplicates.isScanning)
            }
        }
    }
}

// MARK: - Antes da primeira varredura

private struct ShortcutGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Feature.allCases.filter { $0 != .dashboard }) { feature in
                Button { model.selection = feature } label: {
                    HStack(spacing: 12) {
                        Image(systemName: feature.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(feature.tint.gradient))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).font(.headline).foregroundStyle(.primary)
                            Text(feature.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                    .contentShape(.rect)
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
        }
    }
}
