import AppKit
import CleanerCore
import SwiftUI

/// O que o item da barra de menus mostra (Ajustes no próprio menu).
enum MonitorMenuBarStyle: String, CaseIterable, Identifiable {
    case icon, cpu, cpuMem, net

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: "Só o ícone"
        case .cpu: "Processador"
        case .cpuMem: "Processador e memória"
        case .net: "Rede"
        }
    }
}

// MARK: - Rótulo

/// Rótulo do item na barra de menus.
struct MenuBarLabel: View {
    @Environment(\.appModel) private var model
    @AppStorage("menuBarStyle") private var style: MonitorMenuBarStyle = .icon

    var body: some View {
        let monitor = model.monitor
        content(monitor)
            .monospacedDigit()
            // Desligar fica a cargo do ajuste "showMenuBar" (ver MonitorModel.init): um onDisappear
            // espúrio do rótulo congelaria a barra de menus.
            .onAppear { monitor.setActive(true, for: .menuBar) }
    }

    @ViewBuilder private func content(_ monitor: MonitorModel) -> some View {
        switch style {
        case .icon:
            Image(systemName: "sparkles")
                .accessibilityLabel("CleanerCRTV")
        case .cpu:
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                Text(Self.paddedPercent(monitor.cpu?.total))
            }
            .accessibilityLabel("Processador \(Self.paddedPercent(monitor.cpu?.total))")
        case .cpuMem:
            Text("CPU \(Self.paddedPercent(monitor.cpu?.total)) · RAM \(Self.paddedPercent(monitor.memory?.usedFraction))")
        case .net:
            Text("↓ \(Self.rate(monitor.network?.inPerSecond)) ↑ \(Self.rate(monitor.network?.outPerSecond))")
                .accessibilityLabel("Recebendo \(Self.rate(monitor.network?.inPerSecond)), enviando \(Self.rate(monitor.network?.outPerSecond))")
        }
    }

    /// "␣8%" e "12%" com a mesma largura: o resto da barra de menus não fica pulando.
    static func paddedPercent(_ fraction: Double?) -> String {
        guard let fraction else { return MonitorText.placeholder }
        let text = MonitorFormat.percent(fraction)
        return (fraction * 100).rounded() < 10 ? "\u{2007}" + text : text
    }

    static func rate(_ value: Double?) -> String {
        value.map { MonitorFormat.rate($0) } ?? MonitorText.placeholder
    }
}

// MARK: - Painel

/// Conteúdo da janelinha do ícone na barra de menus.
struct MenuBarPanel: View {
    @Environment(\.appModel) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarStyle") private var style: MonitorMenuBarStyle = .icon

    var body: some View {
        let monitor = model.monitor
        VStack(alignment: .leading, spacing: 12) {
            MonitorPanelHeader(monitor: monitor)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    MonitorPanelCPUTile(monitor: monitor)
                    MonitorPanelMemoryTile(monitor: monitor)
                }
                GridRow {
                    MonitorPanelDiskTile(monitor: monitor)
                    MonitorPanelNetworkTile(monitor: monitor)
                }
            }
            if let battery = monitor.battery {
                MonitorPanelBatteryTile(battery: battery)
            }
            MonitorPanelTopApps(monitor: monitor)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MonitorPresence(client: .panel, monitor: monitor))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                openMain(.dashboard)
            } label: {
                Label("Escaneamento inteligente", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.gradient)

            HStack(spacing: 6) {
                Button("Abrir CleanerCRTV") { openMain(nil) }
                    .buttonStyle(.borderless)
                    .fontWeight(.medium)
                Spacer()
                Menu {
                    Picker("Mostrar na barra de menus", selection: $style) {
                        ForEach(MonitorMenuBarStyle.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "menubar.rectangle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("O que mostrar na barra de menus")
                .accessibilityLabel("O que mostrar na barra de menus")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Sair do CleanerCRTV")
                .accessibilityLabel("Sair do CleanerCRTV")
            }
            .padding(.horizontal, 4)
        }
    }

    private func openMain(_ feature: Feature?) {
        if let feature { model.selection = feature }
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MonitorPanelHeader: View {
    let monitor: MonitorModel

    var body: some View {
        let status = MonitorText.status(memory: monitor.memory, thermal: monitor.thermal)
        HStack(spacing: 10) {
            SunburstBadge(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("CleanerCRTV").font(.headline)
                Text(monitor.uptime > 0 ? "Ligado há \(MonitorFormat.uptime(monitor.uptime))" : "Lendo o sistema…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.text).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(.regular.tint(status.color.opacity(0.18)), in: .capsule)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Moldura comum dos quadradinhos do menu.
private struct MonitorPanelTile<Content: View>: View {
    let symbol: String
    let title: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        MonitorCard(padding: 11, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(MonitorTintedIconLabelStyle(tint: tint))
                content
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorTintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct MonitorPanelCPUTile: View {
    let monitor: MonitorModel

    var body: some View {
        MonitorPanelTile(symbol: "cpu", title: "CPU", tint: MonitorPalette.cpu) {
            MonitorBigValue(text: monitor.cpu.map { MonitorFormat.percent($0.total) } ?? MonitorText.placeholder, size: 22)
            MonitorHistoryChart(series: [MonitorChartSeries(name: "Processador", color: MonitorPalette.cpu,
                                                            values: monitor.history.cpu)],
                                maxValue: 1)
                .frame(height: 30)
        }
    }
}

private struct MonitorPanelMemoryTile: View {
    let monitor: MonitorModel

    var body: some View {
        let memory = monitor.memory
        let color = memory.map { MonitorPalette.pressure($0.pressure) } ?? .secondary
        MonitorPanelTile(symbol: "memorychip", title: "Memória", tint: MonitorPalette.memory) {
            MonitorBigValue(text: memory.map { MonitorFormat.percent($0.usedFraction) } ?? MonitorText.placeholder,
                            size: 22, tint: color)
            Text(memory.map { "\(MonitorFormat.memory($0.used)) usada de \(MonitorFormat.memory($0.total))" } ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            MonitorStackedBar(segments: [MonitorBarSegment(id: "used", fraction: memory?.usedFraction ?? 0, color: color)],
                              height: 6)
        }
        .help(memory.map { "Pressão de memória: \(MonitorText.pressure($0.pressure))" } ?? "")
    }
}

private struct MonitorPanelDiskTile: View {
    let monitor: MonitorModel

    var body: some View {
        let volume = monitor.volume
        MonitorPanelTile(symbol: "internaldrive", title: "Disco", tint: MonitorPalette.disk) {
            MonitorBigValue(text: volume.map { $0.available.formattedBytes } ?? MonitorText.placeholder, size: 22)
            Text(volume.map { "livres de \($0.total.formattedBytes)" } ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            MonitorStackedBar(segments: [MonitorBarSegment(id: "used", fraction: volume?.usedFraction ?? 0,
                                                           color: MonitorPalette.load(volume?.usedFraction ?? 0))],
                              height: 6)
        }
    }
}

private struct MonitorPanelNetworkTile: View {
    let monitor: MonitorModel

    var body: some View {
        let network = monitor.network
        MonitorPanelTile(symbol: "network", title: "Rede", tint: MonitorPalette.network) {
            VStack(alignment: .leading, spacing: 1) {
                rateLine("arrow.down", network?.inPerSecond, MonitorPalette.netIn)
                rateLine("arrow.up", network?.outPerSecond, MonitorPalette.netOut)
            }
            MonitorHistoryChart(series: [
                MonitorChartSeries(name: "Recebendo", color: MonitorPalette.netIn, values: monitor.history.netIn),
                MonitorChartSeries(name: "Enviando", color: MonitorPalette.netOut, values: monitor.history.netOut),
            ], minimumScale: 50_000, axisLabel: { MonitorFormat.rate($0) })
            .frame(height: 20)
        }
    }

    private func rateLine(_ symbol: String, _ value: Double?, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(color)
            Text(value.map { MonitorFormat.rate($0) } ?? MonitorText.placeholder)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
        }
    }
}

private struct MonitorPanelBatteryTile: View {
    let battery: MonitorBattery

    var body: some View {
        MonitorCard(padding: 11, cornerRadius: 14, stretches: false) {
            HStack(spacing: 10) {
                Image(systemName: MonitorText.batterySymbol(battery))
                    .font(.system(size: 20))
                    .foregroundStyle(battery.level < 0.2 && !battery.isPluggedIn ? Brand.red : Brand.green)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Bateria").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(MonitorFormat.percent(battery.level)).font(.callout.weight(.semibold).monospacedDigit())
                    }
                    Text(MonitorText.batteryStatus(battery))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                let details = MonitorText.batteryDetails(battery)
                if !details.isEmpty {
                    Text(details.prefix(2).joined(separator: "\n"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorPanelTopApps: View {
    let monitor: MonitorModel

    var body: some View {
        MonitorCard(padding: 11, cornerRadius: 14, stretches: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps que mais usam memória")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !monitor.hasProcesses {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Lendo apps abertos…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                } else if monitor.topApps.isEmpty {
                    Text("Nenhum app aberto agora.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                } else {
                    ForEach(monitor.topApps) { row in
                        MonitorPanelAppRow(row: row, monitor: monitor)
                    }
                }
            }
        }
    }
}

private struct MonitorPanelAppRow: View {
    let row: MonitorProcessRow
    let monitor: MonitorModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            MonitorProcessIcon(bundlePath: row.bundlePath, size: 20)
            Text(row.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if monitor.isTerminating(row) {
                ProgressView().controlSize(.mini)
            } else if hovering, row.canTerminate {
                Button("Encerrar") { monitor.terminate(row) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .transition(.opacity)
            }
            Text(MonitorFormat.memory(row.memory))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(height: 24)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Encerrar") {
            if row.canTerminate { monitor.terminate(row) }
        }
    }
}
