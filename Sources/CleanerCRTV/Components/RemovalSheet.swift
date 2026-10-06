import CleanerCore
import SwiftUI

/// Confirmação única de toda remoção do app. Lixeira por padrão; permanente exige marcar a caixa.
struct RemovalSheet: View {
    let request: RemovalRequest

    @Environment(\.appModel) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: RemovalMode = .trash
    @State private var understood = false
    @State private var running = false
    @State private var done = 0
    @State private var total = 0

    private var totalBytes: Int64 { request.items.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: mode == .trash ? "trash.fill" : "xmark.bin.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(mode == .trash ? Brand.teal : Brand.red)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title ?? "Remover \(request.items.count) \(request.items.count == 1 ? "item" : "itens")?")
                        .font(.title3.weight(.bold))
                    Text("\(totalBytes.formattedBytes) · \(request.source)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            List(request.items.prefix(300)) { item in
                HStack(spacing: 8) {
                    FileIcon(url: item.url, size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.label ?? item.url.lastPathComponent).lineLimit(1)
                        Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: Paths.home.path, with: "~"))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(item.size.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 160, maxHeight: 260)
            if request.items.count > 300 {
                Text("+ \(request.items.count - 300) itens").font(.caption).foregroundStyle(.secondary)
            }

            if let note = request.note {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if request.forcedMode == nil {
                Picker("Modo", selection: $mode) {
                    ForEach(RemovalMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(running)
            }

            Group {
                if mode == .trash {
                    Label("Os itens vão para a Lixeira e podem ser recuperados. O espaço só volta ao esvaziar a Lixeira.",
                          systemImage: "arrow.uturn.backward.circle")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Apagar permanentemente não pode ser desfeito.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Brand.red)
                            .fontWeight(.semibold)
                        Toggle("Entendo que estes arquivos não poderão ser recuperados", isOn: $understood)
                            .disabled(running)
                    }
                }
            }
            .font(.callout)

            HStack {
                if running {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                        .frame(maxWidth: 220)
                    Text("\(done) de \(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button(mode.label) { run() }
                    .buttonStyle(.tinted(mode == .trash ? Brand.teal : Brand.red))
                    .keyboardShortcut(mode == .trash ? .defaultAction : nil)
                    .disabled(running || (mode == .permanent && !understood))
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(running)
        .onAppear {
            mode = request.forcedMode ?? model.defaultRemovalMode
            total = request.items.count
        }
    }

    private func run() {
        running = true
        Task {
            await model.performRemoval(request, mode: mode) { d, t in
                done = d
                total = t
            }
            running = false
            dismiss()
        }
    }
}
