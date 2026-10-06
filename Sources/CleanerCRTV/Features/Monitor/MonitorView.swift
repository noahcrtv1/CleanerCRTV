import AppKit
import CleanerCore
import SwiftUI

/// Tela Monitor: processador, memória, disco, rede, sistema e processos em tempo real.
struct MonitorView: View {
    @Environment(\.appModel) private var model

    var body: some View {
        let monitor = model.monitor
        VStack(spacing: 0) {
            FeatureHeader(feature: .monitor) {
                MonitorMachineChip(info: monitor.systemInfo)
            }
            ScrollView {
                VStack(spacing: 16) {
                    Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow {
                            MonitorCPUCard(monitor: monitor)
                            MonitorMemoryCard(monitor: monitor)
                        }
                        GridRow {
                            MonitorDiskCard(monitor: monitor)
                            MonitorNetworkCard(monitor: monitor)
                        }
                    }
                    MonitorSystemStrip(monitor: monitor)
                    MonitorProcessCard(monitor: monitor)
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.automatic)
        }
        .modifier(MonitorPresence(client: .screen, monitor: monitor))
    }
}

private struct MonitorMachineChip: View {
    let info: MonitorSystemInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
            Text("\(info.cpuBrand) · \(MonitorFormat.memory(info.physicalMemory)) · \(info.osVersion)")
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .help(MonitorText.cores(info))
    }
}

// MARK: - Processador

private struct MonitorCPUCard: View {
    let monitor: MonitorModel

    var body: some View {
        let cpu = monitor.cpu
        MonitorCard {
            VStack(alignment: .leading, spacing: 12) {
                MonitorCardTitle(symbol: "cpu", title: "Processador", tint: MonitorPalette.cpu) {
                    MonitorBigValue(text: cpu.map { MonitorFormat.percent($0.total) } ?? MonitorText.placeholder,
                                    tint: cpu.map { MonitorPalette.load($0.total) } ?? .secondary)
                }
                HStack(spacing: 16) {
                    MonitorLegendItem(color: MonitorPalette.cpu, title: "Usuário",
                                      value: cpu.map { MonitorFormat.percent($0.user) } ?? MonitorText.placeholder)
                        .fixedSize()
                    MonitorLegendItem(color: Brand.violet, title: "Sistema",
                                      value: cpu.map { MonitorFormat.percent($0.system) } ?? MonitorText.placeholder)
                        .fixedSize()
                    Spacer(minLength: 0)
                    if let load = cpu?.loadAverage, load.count == 3 {
                        Text("Carga \(load.map(Self.loadText).joined(separator: " · "))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Média de carga em 1, 5 e 15 minutos")
                    }
                }
                MonitorHistoryChart(series: [MonitorChartSeries(name: "Uso do processador", color: MonitorPalette.cpu,
                                                                values: monitor.history.cpu)],
                                    maxValue: 1, showsAxis: true)
                    .frame(height: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text(MonitorText.cores(monitor.systemInfo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MonitorCoreBars(values: cpu?.perCore ?? Array(repeating: 0, count: monitor.systemInfo.logicalCores))
                        .frame(height: 40)
                }
            }
        }
    }

    private static func loadText(_ value: Double) -> String {
        let hundredths = Int((max(0, value) * 100).rounded())
        return "\(hundredths / 100)\(MonitorFormat.decimalSeparator)\(String(format: "%02d", hundredths % 100))"
    }
}

// MARK: - Memória

private struct MonitorMemoryCard: View {
    let monitor: MonitorModel

    var body: some View {
        let memory = monitor.memory
        let pressureColor = memory.map { MonitorPalette.pressure($0.pressure) } ?? .secondary
        MonitorCard {
            VStack(alignment: .leading, spacing: 12) {
                MonitorCardTitle(symbol: "memorychip", title: "Memória", tint: MonitorPalette.memory) {
                    MonitorBigValue(text: memory.map { MonitorFormat.percent($0.usedFraction) } ?? MonitorText.placeholder,
                                    tint: pressureColor)
                }
                HStack(spacing: 16) {
                    MonitorRing(fraction: memory.map { $0.pressureFraction ?? $0.usedFraction } ?? 0, color: pressureColor,
                                lineWidth: 8) {
                        VStack(spacing: 0) {
                            Text("Pressão").font(.caption2).foregroundStyle(.secondary)
                            Text(memory.map { MonitorText.pressure($0.pressure) } ?? MonitorText.placeholder)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(pressureColor)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .accessibilityElement(children: .combine)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memory.map { "\(MonitorFormat.memory($0.used)) usada de \(MonitorFormat.memory($0.total))" } ?? MonitorText.placeholder)
                            .font(.callout.weight(.semibold).monospacedDigit())
                        Text(memory.map { MonitorText.pressureHint($0.pressure) } ?? " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(swapText(memory?.swap))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let memory {
                    let total = Double(max(1, memory.total))
                    MonitorStackedBar(segments: [
                        MonitorBarSegment(id: "app", fraction: Double(memory.app) / total, color: MonitorPalette.apps),
                        MonitorBarSegment(id: "wired", fraction: Double(memory.wired) / total, color: MonitorPalette.wired),
                        MonitorBarSegment(id: "compressed", fraction: Double(memory.compressed) / total, color: MonitorPalette.compressed),
                        MonitorBarSegment(id: "cached", fraction: Double(memory.cached) / total, color: MonitorPalette.cached.opacity(0.55)),
                    ], height: 12)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        GridRow {
                            MonitorLegendItem(color: MonitorPalette.apps, title: "Apps", value: MonitorFormat.memory(memory.app))
                            MonitorLegendItem(color: MonitorPalette.wired, title: "Fixa", value: MonitorFormat.memory(memory.wired))
                        }
                        GridRow {
                            MonitorLegendItem(color: MonitorPalette.compressed, title: "Comprimida", value: MonitorFormat.memory(memory.compressed))
                            MonitorLegendItem(color: MonitorPalette.cached.opacity(0.55), title: "Arquivos em cache",
                                              value: MonitorFormat.memory(memory.cached))
                        }
                        GridRow {
                            MonitorLegendItem(color: .secondary.opacity(0.35), title: "Livre", value: MonitorFormat.memory(memory.free))
                            Color.clear.frame(height: 1)
                        }
                    }
                }
                MonitorHistoryChart(series: [MonitorChartSeries(name: "Memória usada", color: MonitorPalette.memory,
                                                                values: monitor.history.memory)],
                                    maxValue: 1, showsAxis: true)
                    .frame(height: 56)
            }
        }
    }

    private func swapText(_ swap: MonitorSwap?) -> String {
        guard let swap else { return " " }
        guard swap.used > 0 else { return "Swap: nenhum em uso" }
        return "Swap: \(MonitorFormat.memory(swap.used)) de \(MonitorFormat.memory(swap.total))"
    }
}

// MARK: - Disco

private struct MonitorDiskCard: View {
    let monitor: MonitorModel

    var body: some View {
        let volume = monitor.volume
        let disk = monitor.disk
        MonitorCard {
            VStack(alignment: .leading, spacing: 12) {
                MonitorCardTitle(symbol: "internaldrive", title: "Disco", tint: MonitorPalette.disk) {
                    MonitorBigValue(text: volume.map { "\($0.available.formattedBytes) livres" } ?? MonitorText.placeholder)
                }
                if let volume {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(volume.name) · \(volume.used.formattedBytes) usados de \(volume.total.formattedBytes)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        let total = Double(max(1, volume.total))
                        MonitorStackedBar(segments: [
                            MonitorBarSegment(id: "used", fraction: Double(volume.used) / total,
                                              color: MonitorPalette.load(volume.usedFraction)),
                            MonitorBarSegment(id: "purgeable", fraction: Double(volume.purgeable) / total,
                                              color: MonitorPalette.disk.opacity(0.35)),
                        ], height: 12)
                        if volume.purgeable >= 1_000_000_000 {
                            Text("Inclui \(volume.purgeable.formattedBytes) que o macOS libera sozinho quando precisa")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack(spacing: 16) {
                    MonitorLegendItem(color: MonitorPalette.read, title: "Leitura",
                                      value: disk.map { MonitorFormat.rate($0.readPerSecond) } ?? MonitorText.placeholder)
                        .fixedSize()
                    MonitorLegendItem(color: MonitorPalette.write, title: "Gravação",
                                      value: disk.map { MonitorFormat.rate($0.writePerSecond) } ?? MonitorText.placeholder)
                        .fixedSize()
                }
                MonitorHistoryChart(series: [
                    MonitorChartSeries(name: "Leitura", color: MonitorPalette.read, values: monitor.history.diskRead),
                    MonitorChartSeries(name: "Gravação", color: MonitorPalette.write, values: monitor.history.diskWrite),
                ], minimumScale: 1_000_000, showsAxis: true, axisLabel: { MonitorFormat.rate($0) })
                .frame(minHeight: 90, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Rede

private struct MonitorNetworkCard: View {
    let monitor: MonitorModel

    var body: some View {
        let network = monitor.network
        MonitorCard {
            VStack(alignment: .leading, spacing: 12) {
                MonitorCardTitle(symbol: "network", title: "Rede", tint: MonitorPalette.network) {
                    EmptyView()
                }
                HStack(spacing: 24) {
                    rate("Recebendo", "arrow.down", network?.inPerSecond, MonitorPalette.netIn)
                    rate("Enviando", "arrow.up", network?.outPerSecond, MonitorPalette.netOut)
                    Spacer(minLength: 0)
                }
                MonitorHistoryChart(series: [
                    MonitorChartSeries(name: "Recebendo", color: MonitorPalette.netIn, values: monitor.history.netIn),
                    MonitorChartSeries(name: "Enviando", color: MonitorPalette.netOut, values: monitor.history.netOut),
                ], minimumScale: 100_000, showsAxis: true, axisLabel: { MonitorFormat.rate($0) })
                .frame(minHeight: 110, maxHeight: .infinity)
                if let network {
                    Text("Desde que o Mac ligou: \(Int64(clamping: network.totalIn).formattedBytes) recebidos · \(Int64(clamping: network.totalOut).formattedBytes) enviados")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rate(_ title: String, _ symbol: String, _ value: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            MonitorBigValue(text: value.map { MonitorFormat.rate($0) } ?? MonitorText.placeholder, size: 22)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sistema

private struct MonitorSystemStrip: View {
    let monitor: MonitorModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let battery = monitor.battery {
                tile(symbol: MonitorText.batterySymbol(battery), tint: battery.level < 0.2 && !battery.isPluggedIn ? Brand.red : Brand.green,
                     title: "Bateria", value: MonitorFormat.percent(battery.level),
                     detail: ([MonitorText.batteryStatus(battery)] + [MonitorText.batteryDetails(battery).joined(separator: " · ")].filter { !$0.isEmpty }).joined(separator: "\n"))
            }
            tile(symbol: "thermometer.medium", tint: MonitorPalette.thermal(monitor.thermal),
                 title: "Temperatura", value: MonitorText.thermal(monitor.thermal),
                 detail: MonitorText.thermalHint(monitor.thermal))
            tile(symbol: "clock", tint: Brand.violet, title: "Ligado há",
                 value: monitor.uptime > 0 ? MonitorFormat.uptime(monitor.uptime) : MonitorText.placeholder,
                 detail: monitor.uptime > 14 * 86_400
                    ? "Reiniciar de vez em quando libera memória e aplica atualizações"
                    : "Tempo desde o último reinício")
            tile(symbol: "apple.logo", tint: .gray, title: "Este Mac",
                 value: monitor.systemInfo.osVersion,
                 detail: "\(monitor.systemInfo.cpuBrand)\n\(MonitorText.cores(monitor.systemInfo))")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(symbol: String, tint: Color, title: String, value: String, detail: String) -> some View {
        MonitorCard(padding: 14, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .labelStyle(MonitorStripLabelStyle(tint: tint))
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint == .gray ? .primary : tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorStripLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

// MARK: - Processos

private struct MonitorProcessCard: View {
    let monitor: MonitorModel
    @Environment(\.appModel) private var model
    @State private var selection: MonitorRowID?
    @State private var forceTarget: MonitorProcessRow?

    var body: some View {
        @Bindable var monitor = monitor
        let selected = selection.flatMap { monitor.row($0) }
        MonitorCard(stretches: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Processos").font(.title3.weight(.semibold))
                    Picker("Mostrar", selection: $monitor.scope) {
                        ForEach(MonitorProcessScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 8)
                    searchField($monitor.query)
                    Button("Encerrar") { quit(selected) }
                        .disabled(!(selected?.canTerminate ?? false) || (selected.map(monitor.isTerminating) ?? false))
                    Button("Forçar encerramento…") { forceTarget = selected }
                        .disabled(!(selected?.canTerminate ?? false))
                }
                table(monitor: monitor)
                    .frame(height: 420)
                Text("Mostra os processos da sua conta. Encerrar só vale para apps comuns; componentes do macOS ficam protegidos.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .confirmationDialog("Forçar o encerramento de \(forceTarget?.name ?? "")?",
                            isPresented: Binding(get: { forceTarget != nil }, set: { if !$0 { forceTarget = nil } }),
                            presenting: forceTarget) { row in
            Button("Forçar encerramento", role: .destructive) { forceQuit(row) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("O app fecha na hora, sem perguntar. Alterações que você não salvou serão perdidas.")
        }
    }

    @ViewBuilder private func table(monitor: MonitorModel) -> some View {
        @Bindable var monitor = monitor
        if !monitor.hasProcesses {
            VStack(spacing: 10) {
                ProgressView()
                Text("Lendo processos…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if monitor.visibleRows.isEmpty {
            if monitor.query.isEmpty {
                ContentUnavailableView("Nenhum processo para mostrar", systemImage: "waveform.path.ecg",
                                       description: Text("Assim que algo abrir, aparece aqui."))
            } else {
                ContentUnavailableView.search(text: monitor.query)
            }
        } else {
            Table(monitor.visibleRows, selection: $selection, sortOrder: $monitor.sortOrder) {
                TableColumn("Nome", value: \.name) { row in
                    HStack(spacing: 8) {
                        MonitorProcessIcon(bundlePath: row.bundlePath, size: 18)
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                        if row.processCount > 1 {
                            Text("\(row.processCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help("\(row.processCount) processos somados")
                        }
                        if monitor.isTerminating(row) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .width(min: 200, ideal: 320)
                TableColumn("CPU", value: \.cpu) { row in
                    Text(monitor.processCPUValid ? MonitorFormat.percent(row.cpu, decimals: 1) : MonitorText.placeholder)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Memória", value: \.memory) { row in
                    Text(MonitorFormat.memory(row.memory))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100)
                TableColumn("PID", value: \.pid) { row in
                    Text(String(row.pid))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 70)
            }
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: MonitorRowID.self) { ids in
                if let id = ids.first, let row = monitor.row(id) {
                    Button("Encerrar") { quit(row) }
                        .disabled(!row.canTerminate)
                    Button("Forçar encerramento…") { forceTarget = row }
                        .disabled(!row.canTerminate)
                    Divider()
                    if let path = row.bundlePath ?? row.executablePath {
                        Button("Mostrar no Finder") { Reveal.inFinder(URL(fileURLWithPath: path)) }
                    }
                    Button("Copiar PID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(row.pid), forType: .string)
                    }
                }
            }
        }
    }

    private func searchField(_ text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar processo", text: text)
                .textFieldStyle(.plain)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: 200)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private func quit(_ row: MonitorProcessRow?) {
        guard let row else { return }
        if monitor.terminate(row) {
            model.showToast("Pedimos para \(row.name) encerrar", symbol: "xmark.circle.fill")
        } else {
            model.showToast("Não foi possível encerrar \(row.name)", symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    private func forceQuit(_ row: MonitorProcessRow) {
        if monitor.terminate(row, force: true) {
            model.showToast("\(row.name) foi encerrado à força", symbol: "xmark.octagon.fill")
        } else {
            model.showToast("Não foi possível encerrar \(row.name)", symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }
}
