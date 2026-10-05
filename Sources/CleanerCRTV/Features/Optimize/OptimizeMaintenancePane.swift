import CleanerCore
import SwiftUI

/// Tarefas de manutenção em cartões. As que pedem senha só pedem quando você clica.
struct OptimizeMaintenancePane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text("As tarefas com cadeado pedem sua senha de administrador na janela do próprio macOS, só quando você clica em Executar. O CleanerCRTV não instala nenhum ajudante com privilégios.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(Feature.optimize.tint)
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(app.optimize.tasks) { task in
                        OptimizeTaskCard(task: task)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }
}

private struct OptimizeTaskCard: View {
    let task: OptimizeMaintenanceTask

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirming = false
    @State private var showDetails = false

    private var model: OptimizeModel { app.optimize }
    private var isRunning: Bool { model.runningTasks.contains(task.id) }
    private var outcome: OptimizeTaskOutcome? { model.outcomes[task.id] }
    private var tint: Color { Self.tint(for: task.id) }

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                header
                Text(task.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = task.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Brand.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = passwordNote {
                    Label(note, systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let outcome, !isRunning {
                    result(outcome)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer
            }
        }
        .animation(Motion.standard(reduceMotion), value: isRunning)
        .animation(Motion.standard(reduceMotion), value: outcome)
        .alert("\(task.title)?", isPresented: $confirming) {
            Button("Executar") { model.run(task) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(task.confirmationMessage ?? task.explanation)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.headline)
                HStack(spacing: 6) {
                    switch task.privilege {
                    case .admin: OptimizeTag(text: "pede senha", color: Brand.orange)
                    case .userThenAdmin: OptimizeTag(text: "pode pedir senha", color: Brand.orange)
                    case .user: OptimizeTag(text: "sem senha", color: Brand.green)
                    }
                    Text(task.duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if task.privilege != .user {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Brand.orange)
                    .accessibilityLabel("Pede senha de administrador")
            }
        }
    }

    private var passwordNote: String? {
        switch task.privilege {
        case .admin: "Pede a senha de administrador só quando você clicar em Executar."
        case .userThenAdmin: "Roda sem senha; se o macOS exigir, você pode repetir com a senha."
        case .user: nil
        }
    }

    @ViewBuilder
    private func result(_ outcome: OptimizeTaskOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(outcome.message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: Self.symbol(for: outcome.status))
                    .foregroundStyle(Self.color(for: outcome.status))
            }
            .font(.callout.weight(.medium))

            if let details = outcome.details {
                DisclosureGroup("Detalhes", isExpanded: $showDetails) {
                    ScrollView {
                        Text(details)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.color(for: outcome.status).opacity(0.08)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let last = model.lastRuns[task.id] {
                Text("Última vez \(last, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(last.formatted(date: .long, time: .shortened))
            } else {
                Text("Nunca executada").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if isRunning {
                ProgressView().controlSize(.small)
                Text(task.privilege == .admin ? "Aguardando o macOS…" : "Executando…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.stoppableTasks.contains(task.id) {
                    Button("Parar") { model.stop(task) }
                        .controlSize(.small)
                }
            } else {
                if outcome?.canRetryAsAdmin == true {
                    Button("Tentar com senha") { model.run(task, asAdmin: true) }
                }
                Button("Executar") {
                    if task.needsConfirmation { confirming = true } else { model.run(task) }
                }
                .buttonStyle(.tinted(tint))
            }
        }
    }

    // MARK: Cores

    static func tint(for id: String) -> Color {
        switch id {
        case OptimizeMaintenanceCatalog.freeMemory.id: Brand.teal
        case OptimizeMaintenanceCatalog.flushDNS.id: Brand.violet
        case OptimizeMaintenanceCatalog.restartFinderDock.id: Brand.green
        case OptimizeMaintenanceCatalog.resetQuickLook.id: Brand.magenta
        case OptimizeMaintenanceCatalog.rebuildLaunchServices.id: Brand.orange
        case OptimizeMaintenanceCatalog.reindexSpotlight.id: Brand.violet
        case OptimizeMaintenanceCatalog.verifyDisk.id: Brand.red
        default: Feature.optimize.tint
        }
    }

    static func symbol(for status: OptimizeTaskOutcome.Status) -> String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    static func color(for status: OptimizeTaskOutcome.Status) -> Color {
        switch status {
        case .success: Brand.green
        case .warning: Brand.orange
        case .failure: Brand.red
        case .cancelled: .secondary
        }
    }
}
