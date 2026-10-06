import AppKit
import Charts
import CleanerCore
import SwiftUI

// MARK: - Visibilidade

/// Liga o cliente no monitor enquanto a view está na tela e a janela dela visível de fato
/// (minimizada, escondida ou o menu fechado contam como fora de vista).
struct MonitorPresence: ViewModifier {
    let client: MonitorClient
    let monitor: MonitorModel
    @State private var appeared = false
    @State private var windowVisible = true

    func body(content: Content) -> some View {
        content
            .background(MonitorWindowVisibilityReader { windowVisible = $0 })
            .onAppear { appeared = true; update() }
            .onDisappear { appeared = false; update() }
            .onChange(of: windowVisible) { update() }
    }

    private func update() {
        monitor.setActive(appeared && windowVisible, for: client)
    }
}

struct MonitorWindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> MonitorVisibilityView {
        let view = MonitorVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MonitorVisibilityView, context: Context) {
        view.onChange = onChange
    }
}

final class MonitorVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else {
            report(false)
            return
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportCurrent() }
        }
        reportCurrent()
    }

    private func reportCurrent() {
        guard let window else { return report(false) }
        report(window.isVisible && window.occlusionState.contains(.visible))
    }

    private func report(_ visible: Bool) {
        guard visible != lastReported else { return }
        lastReported = visible
        // Fora do ciclo de atualização do SwiftUI (mudar estado durante a montagem gera aviso).
        DispatchQueue.main.async { [onChange] in onChange?(visible) }
    }
}

// MARK: - Cartões

/// Cartão de vidro que estica até a altura da linha (cartões lado a lado ficam iguais).
struct MonitorCard<Content: View>: View {
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 18
    /// false = só a altura do conteúdo (listas soltas, fora de linhas de cartões).
    var stretches = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: stretches ? .infinity : nil, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// Título de cartão: ícone colorido + nome, valor grande à direita.
struct MonitorCardTitle<Trailing: View>: View {
    let symbol: String
    let title: String
    let tint: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Número grande em fonte arredondada, com dígitos de largura fixa.
struct MonitorBigValue: View {
    let text: String
    var size: CGFloat = 26
    var tint: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(tint)
            .contentTransition(.numericText())
            .lineLimit(1)
    }
}

/// Bolinha colorida + rótulo + valor (legendas).
struct MonitorLegendItem: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gráficos

struct MonitorChartSeries: Identifiable {
    let name: String
    let color: Color
    let values: [Double]
    var id: String { name }
}

/// Histórico em área + linha. O mais recente fica colado à direita; o vazio à esquerda
/// vai sendo preenchido nos primeiros minutos.
struct MonitorHistoryChart: View {
    let series: [MonitorChartSeries]
    var capacity = MonitorModel.historyLength
    /// Escala fixa (1 para frações); nil = automática.
    var maxValue: Double?
    /// Piso da escala automática (sem isso, 2 KB/s de ruído ocupariam o gráfico inteiro).
    var minimumScale: Double = 1
    var showsAxis = false
    var axisLabel: (Double) -> String = { MonitorFormat.percent($0) }

    var body: some View {
        Chart {
            ForEach(series) { line in
                let offset = capacity - line.values.count
                ForEach(Array(line.values.enumerated()), id: \.offset) { index, value in
                    AreaMark(x: .value("Tempo", index + offset), y: .value("Valor", value),
                             series: .value("Série", line.name), stacking: .unstacked)
                        .foregroundStyle(LinearGradient(colors: [line.color.opacity(0.32), line.color.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Tempo", index + offset), y: .value("Valor", value),
                             series: .value("Série", line.name))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: 0...max(1, capacity - 1))
        .chartYScale(domain: 0...upperBound)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [upperBound / 2, upperBound]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis(showsAxis ? .automatic : .hidden)
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map(\.name).joined(separator: " e "))
        .accessibilityValue(series.compactMap { $0.values.last.map(axisLabel) }.joined(separator: ", "))
    }

    private var upperBound: Double {
        if let maxValue { return maxValue }
        let peak = series.lazy.flatMap(\.values).max() ?? 0
        return Self.niceCeiling(max(peak * 1.1, minimumScale))
    }

    /// Arredonda para 1, 2 ou 5 × 10ⁿ (marcas do eixo legíveis).
    private static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 2, 5, 10] where step * magnitude >= value { return step * magnitude }
        return 10 * magnitude
    }
}

// MARK: - Barras e anéis

struct MonitorBarSegment: Identifiable {
    let id: String
    let fraction: Double
    let color: Color
}

/// Barra horizontal em partes (memória por tipo, disco usado/liberável).
struct MonitorStackedBar: View {
    let segments: [MonitorBarSegment]
    var height: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let visible = segments.filter { $0.fraction > 0.003 }
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(1, (geo.size.width - gaps) * min(1, segment.fraction)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.7))
        .clipShape(Capsule())
        .animation(Motion.standard(reduceMotion), value: segments.map(\.fraction))
    }
}

/// Anel de progresso com conteúdo no meio.
struct MonitorRing<Label: View>: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 8
    @ViewBuilder var label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.005, min(1, fraction)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label
        }
        .padding(lineWidth / 2)
        .animation(Motion.standard(reduceMotion), value: fraction)
    }
}

/// Uma barrinha vertical por núcleo.
struct MonitorCoreBars: View {
    let values: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: values.count > 16 ? 2 : 4) {
            ForEach(values.indices, id: \.self) { index in
                let value = min(1, max(0, values[index]))
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.quaternary.opacity(0.7))
                        Capsule()
                            .fill(MonitorPalette.load(value).gradient)
                            .frame(height: max(geo.size.width, geo.size.height * value))
                    }
                }
                .help("Núcleo \(index + 1): \(MonitorFormat.percent(value))")
            }
        }
        .animation(Motion.standard(reduceMotion), value: values)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uso por núcleo")
        .accessibilityValue(values.map { MonitorFormat.percent($0) }.joined(separator: ", "))
    }
}

/// Ícone de um processo: o do app quando há pacote, um genérico quando não.
struct MonitorProcessIcon: View {
    let bundlePath: String?
    var size: CGFloat = 18

    var body: some View {
        if let bundlePath {
            FileIcon(url: URL(fileURLWithPath: bundlePath), size: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.6, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(.quaternary.opacity(0.6)))
        }
    }
}

// MARK: - Cores e textos

enum MonitorPalette {
    static let cpu = Brand.teal
    static let memory = Brand.violet
    static let disk = Brand.orange
    static let network = Brand.magenta
    static let netIn = Brand.teal
    static let netOut = Brand.magenta
    static let read = Brand.teal
    static let write = Brand.orange
    static let apps = Brand.violet
    static let wired = Brand.orange
    static let compressed = Brand.magenta
    static let cached = Brand.teal

    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: Brand.green
        case ..<0.85: Brand.orange
        default: Brand.red
        }
    }

    static func pressure(_ level: MonitorMemoryPressure) -> Color {
        switch level {
        case .normal: Brand.green
        case .warning: Brand.orange
        case .critical: Brand.red
        }
    }

    static func thermal(_ state: MonitorThermalState) -> Color {
        switch state {
        case .nominal: Brand.green
        case .fair: Brand.teal
        case .serious: Brand.orange
        case .critical: Brand.red
        }
    }
}

enum MonitorText {
    static let placeholder = "—"

    static func pressure(_ level: MonitorMemoryPressure) -> String {
        switch level {
        case .normal: "Normal"
        case .warning: "Alta"
        case .critical: "Crítica"
        }
    }

    static func pressureHint(_ level: MonitorMemoryPressure) -> String {
        switch level {
        case .normal: "Sobra memória para o que você está fazendo"
        case .warning: "O macOS está comprimindo memória para dar conta"
        case .critical: "Feche apps que você não está usando"
        }
    }

    static func thermal(_ state: MonitorThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Moderada"
        case .serious: "Alta"
        case .critical: "Crítica"
        }
    }

    static func thermalHint(_ state: MonitorThermalState) -> String {
        switch state {
        case .nominal: "Desempenho máximo disponível"
        case .fair: "As ventoinhas podem acelerar"
        case .serious: "O macOS está reduzindo o desempenho"
        case .critical: "Desempenho bem reduzido para esfriar"
        }
    }

    static func batterySymbol(_ battery: MonitorBattery) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func batteryStatus(_ battery: MonitorBattery) -> String {
        if battery.isCharging {
            return battery.minutesToFull.map { "Carregando · \(MonitorFormat.minutes($0)) para completar" } ?? "Carregando"
        }
        if battery.isPluggedIn {
            return battery.isCharged || battery.level >= 0.99 ? "Carregada" : "Na tomada, sem carregar"
        }
        return battery.minutesToEmpty.map { "\(MonitorFormat.minutes($0)) restantes" } ?? "Calculando o tempo restante…"
    }

    static func batteryDetails(_ battery: MonitorBattery) -> [String] {
        var parts: [String] = []
        if let health = battery.health { parts.append("Saúde \(MonitorFormat.percent(health))") }
        if let cycles = battery.cycleCount { parts.append("\(cycles) \(cycles == 1 ? "ciclo" : "ciclos")") }
        if let temperature = battery.temperature { parts.append("\(Int(temperature.rounded())) °C") }
        return parts
    }

    static func cores(_ info: MonitorSystemInfo) -> String {
        if let performance = info.performanceCores, let efficiency = info.efficiencyCores, efficiency > 0 {
            return "\(info.logicalCores) núcleos (\(performance) de desempenho, \(efficiency) de eficiência)"
        }
        return "\(info.logicalCores) núcleos"
    }

    /// Resumo da saúde do Mac para o selo do menu.
    static func status(memory: MonitorMemory?, thermal: MonitorThermalState) -> (text: String, color: Color) {
        if thermal >= .serious { return ("Mac aquecido", MonitorPalette.thermal(thermal)) }
        if let memory, memory.pressure != .normal {
            return (memory.pressure == .critical ? "Memória no limite" : "Memória apertada", MonitorPalette.pressure(memory.pressure))
        }
        return ("Tudo certo", Brand.green)
    }
}
