import SwiftUI

// MARK: - Marca

enum Brand {
    static let red = Color(red: 1.00, green: 0.23, blue: 0.25)
    static let magenta = Color(red: 0.86, green: 0.18, blue: 0.55)
    static let violet = Color(red: 0.45, green: 0.22, blue: 0.85)
    static let teal = Color(red: 0.10, green: 0.75, blue: 0.85)
    static let green = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let orange = Color(red: 1.00, green: 0.60, blue: 0.12)

    /// Mesmo gradiente da família CRTV (vermelho → magenta → violeta → turquesa).
    static let gradient = LinearGradient(
        stops: [.init(color: red, location: 0), .init(color: magenta, location: 0.38),
                .init(color: violet, location: 0.68), .init(color: teal, location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let bands: [Color] = [red, magenta, violet, teal]

    /// Fundo escuro do ícone.
    static let ink = Color(red: 0.07, green: 0.06, blue: 0.13)
}

/// Molas da casa: amortecimento crítico por padrão; quique só depois de gesto com impulso.
enum Motion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)
    static let quick = Animation.spring(response: 0.25, dampingFraction: 1.0)
    static let settle = Animation.spring(response: 0.45, dampingFraction: 1.0)
    static let momentum = Animation.spring(response: 0.35, dampingFraction: 0.8)

    static func standard(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.18) : standard }
    static func quick(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.12) : quick }
}

// MARK: - Símbolo: disco em raios de sol com brilho (grade 120×120)

/// Setor de anel. Ângulos em graus, 0 = topo, sentido horário. `sweep` (0…1) anima o fim do setor.
struct RingSegment: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat
    var sweep: Double = 1

    var animatableData: Double {
        get { sweep }
        set { sweep = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 120
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let endAngle = start + (end - start) * max(0, min(1, sweep))
        guard endAngle > start else { return Path() }
        func point(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: center.x + radius * s * sin(r), y: center.y - radius * s * cos(r))
        }
        let steps = max(2, Int((endAngle - start) / 2))
        var p = Path()
        p.move(to: point(start, outer))
        for i in 1...steps { p.addLine(to: point(start + (endAngle - start) * Double(i) / Double(steps), outer)) }
        for i in stride(from: steps, through: 0, by: -1) {
            p.addLine(to: point(start + (endAngle - start) * Double(i) / Double(steps), inner))
        }
        p.closeSubpath()
        return p
    }
}

/// Brilho de 4 pontas (o "limpo").
struct SparkleShape: Shape {
    var cx: CGFloat = 60
    var cy: CGFloat = 60
    var radius: CGFloat = 13
    var pinch: CGFloat = 0.2

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 120
        let ox = rect.midX - 60 * s, oy = rect.midY - 60 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let r = radius, k = radius * pinch
        var p = Path()
        p.move(to: pt(cx, cy - r))
        p.addQuadCurve(to: pt(cx + r, cy), control: pt(cx + k, cy - k))
        p.addQuadCurve(to: pt(cx, cy + r), control: pt(cx + k, cy + k))
        p.addQuadCurve(to: pt(cx - r, cy), control: pt(cx - k, cy + k))
        p.addQuadCurve(to: pt(cx, cy - r), control: pt(cx - k, cy - k))
        p.closeSubpath()
        return p
    }
}

enum MarkGeometry {
    struct Segment { let start: Double; let end: Double; let inner: CGFloat; let outer: CGFloat; let color: Color; let opacity: Double }

    /// Anel interno (categorias) e externo (subpastas), com vãos de espaço livre.
    static let segments: [Segment] = [
        .init(start: 4, end: 136, inner: 19, outer: 31, color: Brand.red, opacity: 1),
        .init(start: 142, end: 246, inner: 19, outer: 31, color: Brand.magenta, opacity: 1),
        .init(start: 252, end: 316, inner: 19, outer: 31, color: Brand.violet, opacity: 1),
        .init(start: 322, end: 356, inner: 19, outer: 31, color: Brand.teal, opacity: 1),
        .init(start: 4, end: 84, inner: 34, outer: 46, color: Brand.red, opacity: 0.85),
        .init(start: 88, end: 128, inner: 34, outer: 46, color: Brand.red, opacity: 0.6),
        .init(start: 142, end: 212, inner: 34, outer: 46, color: Brand.magenta, opacity: 0.8),
        .init(start: 252, end: 298, inner: 34, outer: 46, color: Brand.violet, opacity: 0.8),
        .init(start: 322, end: 342, inner: 34, outer: 46, color: Brand.teal, opacity: 0.8),
    ]
}

/// Símbolo completo. Os parâmetros servem à animação de abertura; os padrões dão o símbolo pronto.
struct SunburstMark: View {
    var rings: Double = 1
    var sparkle: Double = 1
    var glow: Double = 0

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 120
            ZStack {
                ForEach(Array(MarkGeometry.segments.enumerated()), id: \.offset) { i, seg in
                    let stagger = max(0, min(1, rings * 1.6 - Double(i % 5) * 0.12 - (seg.inner > 30 ? 0.25 : 0)))
                    RingSegment(start: seg.start, end: seg.end, inner: seg.inner, outer: seg.outer, sweep: stagger)
                        .fill(seg.color.opacity(seg.opacity))
                        .shadow(color: seg.color.opacity(0.5 * glow), radius: 7 * s)
                }
                SparkleShape(radius: 14)
                    .fill(.white)
                    .scaleEffect(0.3 + 0.7 * sparkle)
                    .rotationEffect(.degrees(-45 * (1 - sparkle)))
                    .opacity(sparkle)
                    .shadow(color: .white.opacity(0.6 * glow), radius: 8 * s)
                SparkleShape(cx: 100, cy: 20, radius: 7.5)
                    .fill(.white.opacity(0.9))
                    .scaleEffect(sparkle, anchor: UnitPoint(x: 100 / 120, y: 20 / 120))
                    .opacity(sparkle)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Símbolo sobre o quadrado escuro do ícone (para abertura, painel e "Sobre").
struct SunburstBadge: View {
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.09, blue: 0.21), Color(red: 0.04, green: 0.04, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
            SunburstMark(glow: 0.6)
                .padding(size * 0.08)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Abertura

/// Anéis varrem em leque, o brilho acende girando; some dissolvendo.
struct OpeningView: View {
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plate = 0.0
    @State private var rings = 0.0
    @State private var sparkle = 0.0
    @State private var glow = 0.0
    @State private var title = 0.0
    @State private var leaving = false

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 18) {
                SunburstMark(rings: rings, sparkle: sparkle, glow: glow)
                    .frame(width: 150, height: 150)
                    .background {
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .fill(Brand.ink)
                            .frame(width: 176, height: 176)
                            .opacity(plate)
                            .scaleEffect(0.9 + 0.1 * plate)
                    }
                    .padding(.bottom, 12)
                Text("CleanerCRTV")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                    .opacity(title)
                    .offset(y: (1 - title) * 8)
            }
            .scaleEffect(leaving ? 1.06 : 1)
            .blur(radius: leaving ? 12 : 0)
            .opacity(leaving ? 0 : 1)
        }
        .contentShape(.rect)
        .onTapGesture { finish() }
        .task { await run() }
    }

    private func run() async {
        if reduceMotion {
            plate = 1; rings = 1; sparkle = 1; title = 1
            try? await Task.sleep(for: .milliseconds(700))
            finish()
            return
        }
        withAnimation(Motion.standard) { plate = 1 }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeOut(duration: 0.6)) { rings = 1 }
        try? await Task.sleep(for: .milliseconds(420))
        withAnimation(Motion.momentum) { sparkle = 1 }
        withAnimation(.easeOut(duration: 0.25)) { glow = 1 }
        try? await Task.sleep(for: .milliseconds(160))
        withAnimation(Motion.standard) { title = 1 }
        try? await Task.sleep(for: .milliseconds(650))
        finish()
    }

    private func finish() {
        guard !leaving else { return }
        withAnimation(.easeIn(duration: 0.3)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onFinish() }
    }
}
