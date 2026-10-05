import AppKit
import CleanerCore
import SwiftUI

// MARK: - Cabeçalho de tela

/// Cabeçalho padrão de cada tela: ícone colorido, título, subtítulo e ações à direita.
struct FeatureHeader<Trailing: View>: View {
    let feature: Feature
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(feature: Feature, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.feature = feature
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(feature.tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle ?? feature.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

// MARK: - Botões

/// Feedback no pointer-down, instantâneo.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Botão principal em pílula com o gradiente da marca ("Escanear", "Limpar").
struct GradientButtonStyle: ButtonStyle {
    var tint: AnyShapeStyle = AnyShapeStyle(Brand.gradient)
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 17 : 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 30 : 18)
            .padding(.vertical, large ? 13 : 8)
            .background(Capsule().fill(tint))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == GradientButtonStyle {
    static var gradient: GradientButtonStyle { GradientButtonStyle() }
    static var gradientLarge: GradientButtonStyle { GradientButtonStyle(large: true) }
    static func tinted(_ color: Color, large: Bool = false) -> GradientButtonStyle {
        GradientButtonStyle(tint: AnyShapeStyle(color.gradient), large: large)
    }
}

// MARK: - Estados de varredura

/// Tela de entrada de um módulo antes da primeira varredura.
struct ScanHero: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var buttonTitle = "Escanear"
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 150, height: 150)
                Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1).frame(width: 190, height: 190)
                Image(systemName: symbol)
                    .font(.system(size: 58, weight: .regular))
                    .foregroundStyle(tint.gradient)
            }
            .padding(.bottom, 6)
            Text(title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(buttonTitle, action: action)
                .buttonStyle(.gradientLarge)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Varredura em andamento: anel girando, o que está sendo lido e botão de parar.
struct ScanningView: View {
    var title = "Escaneando…"
    /// Caminho ou etapa atual (pode mudar muito rápido; é só informativo).
    var detail: String?
    /// 0…1 quando se sabe o total; nil = indeterminado.
    var progress: Double?
    /// Algo como "12.345 arquivos · 3,2 GB".
    var counter: String?
    var onCancel: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: progress)
                } else {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                }
                SunburstMark(rings: 1, sparkle: 1)
                    .frame(width: 70, height: 70)
                    .opacity(0.9)
            }
            .frame(width: 130, height: 130)
            .onAppear { spin = true }
            Text(title).font(.title3.weight(.semibold))
            if let counter {
                Text(counter).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            }
            if let onCancel {
                Button("Parar", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rodapé de ação

/// Barra fixa no pé da tela: resumo da seleção + ação principal.
struct ActionBar<Leading: View>: View {
    let summary: String
    let buttonTitle: String
    var enabled = true
    var tint: Color?
    @ViewBuilder var leading: Leading
    let action: () -> Void

    init(summary: String, buttonTitle: String, enabled: Bool = true, tint: Color? = nil,
         @ViewBuilder leading: () -> Leading = { EmptyView() }, action: @escaping () -> Void) {
        self.summary = summary
        self.buttonTitle = buttonTitle
        self.enabled = enabled
        self.tint = tint
        self.leading = leading()
        self.action = action
    }

    var body: some View {
        HStack(spacing: 14) {
            leading
            Spacer()
            Text(summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Button(buttonTitle, action: action)
                .buttonStyle(tint.map { GradientButtonStyle(tint: AnyShapeStyle($0.gradient)) } ?? GradientButtonStyle())
                .disabled(!enabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Peças pequenas

/// Caixa de seleção de três estados (lista com grupos).
struct TriStateCheckbox: View {
    enum CheckState { case on, off, mixed }
    let state: CheckState
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(state == .off ? AnyShapeStyle(.background) : AnyShapeStyle(tint))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(state == .off ? AnyShapeStyle(.secondary.opacity(0.6)) : AnyShapeStyle(tint), lineWidth: 1)
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 15, height: 15)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }
}

/// Número de bytes em fonte de largura fixa.
struct SizeText: View {
    let bytes: Int64
    var weight: Font.Weight = .medium

    var body: some View {
        Text(bytes.formattedBytes)
            .font(.body.monospacedDigit().weight(weight))
            .contentTransition(.numericText())
    }
}

/// Bloco de número grande com rótulo (painel, histórico).
struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = .accentColor
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
    }
}

/// Cartão de vidro (Liquid Glass) para agrupar conteúdo.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
