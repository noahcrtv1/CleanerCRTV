import CleanerCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(FeatureSection.allCases) { section in
                Section(section.title) {
                    ForEach(section.features) { feature in
                        SidebarRow(feature: feature, badge: model.badge(for: feature))
                            .tag(feature)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DiskFooter() }
    }
}

private struct SidebarRow: View {
    let feature: Feature
    let badge: String?

    var body: some View {
        Label {
            Text(feature.title)
        } icon: {
            Image(systemName: feature.symbol)
                .foregroundStyle(feature.tint)
        }
        .badge(badge.map { Text($0).monospacedDigit() })
    }
}

/// Espaço livre do disco de inicialização, sempre visível no pé da barra lateral.
private struct DiskFooter: View {
    @State private var usage = VolumeUsage.startup()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text(usage.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
            }
            UsageBar(fraction: usage.usedFraction)
                .frame(height: 6)
            Text("\(usage.available.formattedBytes) livres de \(usage.total.formattedBytes)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task {
            while !Task.isCancelled {
                usage = VolumeUsage.startup()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

/// Barra de uso com o gradiente da marca; fica vermelha acima de 90%.
struct UsageBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.9 ? AnyShapeStyle(Brand.red) : AnyShapeStyle(Brand.gradient))
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}
