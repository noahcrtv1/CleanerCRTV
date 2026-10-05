import CleanerCore
import SwiftUI

struct OptimizeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = app.optimize
        VStack(spacing: 0) {
            FeatureHeader(feature: .optimize) {
                if model.section == .agents, model.hasScanned {
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await model.scan() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Ler os agentes de novo")
                        .accessibilityLabel("Atualizar agentes")
                    }
                }
            }

            Picker("Seção", selection: $model.section.animation(Motion.standard(reduceMotion))) {
                ForEach(OptimizeModel.Section.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            Group {
                switch model.section {
                case .agents: OptimizeAgentsPane()
                case .loginItems: OptimizeLoginItemsPane()
                case .maintenance: OptimizeMaintenancePane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Agentes de inicialização

private struct OptimizeAgentsPane: View {
    @Environment(AppModel.self) private var app
    @State private var selection: Set<OptimizeLaunchAgent.ID> = []

    var body: some View {
        let model = app.optimize
        if model.isScanning && !model.hasScanned {
            ScanningView(title: "Lendo os agentes…", detail: model.scanStatus) { model.cancel() }
        } else if !model.hasScanned {
            ScanHero(symbol: "gearshape.2", tint: Feature.optimize.tint, title: "Agentes de inicialização",
                     message: "Veja o que abre sozinho quando você liga o Mac ou inicia a sessão, desative o que não precisa e remova agentes quebrados de apps que já saíram.") {
                Task { await model.scan() }
            }
        } else {
            VStack(spacing: 0) {
                stats
                filterBar
                if model.groups.isEmpty {
                    emptyState
                } else {
                    list
                }
                ActionBar(summary: brokenSummary(model), buttonTitle: "Remover quebrados…",
                          enabled: !model.brokenRemovable.isEmpty, tint: Brand.red) {
                    Button {
                        Reveal.inFinder(OptimizeAgentScope.user.directory)
                    } label: {
                        Label("Abrir pasta", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Mostrar ~/Library/LaunchAgents no Finder")
                } action: {
                    remove(model.brokenRemovable)
                }
            }
        }
    }

    private var stats: some View {
        let model = app.optimize
        return HStack(spacing: 36) {
            StatTile(title: "Seus agentes", value: "\(model.userAgentCount)", tint: Feature.optimize.tint, symbol: "person.fill")
            StatTile(title: "Em execução", value: "\(model.runningCount)", tint: Brand.teal, symbol: "play.circle.fill")
            StatTile(title: "Quebrados", value: "\(model.brokenUserCount)",
                     tint: model.brokenUserCount > 0 ? Brand.red : .secondary, symbol: "exclamationmark.triangle.fill")
            StatTile(title: "Do sistema", value: "\(model.systemAgentCount)", tint: .secondary, symbol: "lock.fill")
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private var filterBar: some View {
        let model = app.optimize
        return HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar por nome, rótulo ou programa", text: Bindable(model).searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Limpar busca")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: .capsule)

            Toggle("Mostrar agentes do sistema", isOn: Bindable(model).showSystem)
                .toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }

    private var list: some View {
        let model = app.optimize
        return List(selection: $selection) {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.agents) { agent in
                        OptimizeAgentRow(agent: agent, isBusy: model.busyAgents.contains(agent.id)) { enabled in
                            toggle(agent, enabled)
                        }
                        .tag(agent.id)
                    }
                } header: {
                    OptimizeGroupHeader(scope: group.scope, count: group.agents.count)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: OptimizeLaunchAgent.ID.self) { ids in
            contextMenu(for: model.agents(withIDs: ids))
        } primaryAction: { ids in
            Reveal.inFinder(model.agents(withIDs: ids).map(\.url))
        }
    }

    @ViewBuilder
    private func contextMenu(for agents: [OptimizeLaunchAgent]) -> some View {
        if agents.count == 1, let agent = agents.first {
            FileContextMenu(url: agent.url)
            if let program = agent.programURL, !agent.isBroken {
                Button("Mostrar o programa no Finder") { Reveal.inFinder(program) }
            }
            if let owner = agent.owner {
                Button("Mostrar \(owner.name) no Finder") { Reveal.inFinder(owner.url) }
            }
            if agent.isManageable {
                Divider()
                Button(agent.isEnabled ? "Desativar" : "Ativar") { toggle(agent, !agent.isEnabled) }
            }
            if agent.isRemovable {
                Divider()
                Button("Remover…", role: .destructive) { remove([agent]) }
            }
        } else if !agents.isEmpty {
            Button("Mostrar no Finder") { Reveal.inFinder(agents.map(\.url)) }
            let removable = agents.filter(\.isRemovable)
            if !removable.isEmpty {
                Divider()
                Button("Remover \(removable.count) \(removable.count == 1 ? "agente" : "agentes")…", role: .destructive) {
                    remove(removable)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let model = app.optimize
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView {
                Label("Nada abre sozinho", systemImage: "checkmark.seal")
            } description: {
                Text(model.showSystem
                     ? "Nenhum agente além dos do próprio macOS. Seu Mac começa leve."
                     : "Você não tem agentes próprios. Marque “Mostrar agentes do sistema” para ver os de /Library.")
            }
        }
    }

    private func brokenSummary(_ model: OptimizeModel) -> String {
        switch model.brokenRemovable.count {
        case 0: "Nenhum agente quebrado"
        case 1: "1 agente quebrado: o macOS não consegue mais abri-lo"
        case let n: "\(n) agentes quebrados: o macOS não consegue mais abri-los"
        }
    }

    // MARK: Ações

    private func toggle(_ agent: OptimizeLaunchAgent, _ enabled: Bool) {
        let model = app.optimize
        Task {
            if let error = await model.setEnabled(agent, enabled) {
                app.showToast("Não foi possível \(enabled ? "ativar" : "desativar") “\(agent.displayName)”: \(error)",
                              symbol: "exclamationmark.triangle.fill", isError: true)
            } else {
                app.showToast(enabled
                              ? "“\(agent.displayName)” ativado: volta a abrir sozinho"
                              : "“\(agent.displayName)” desativado: não abre mais sozinho",
                              symbol: enabled ? "play.circle.fill" : "pause.circle.fill")
            }
        }
    }

    private func remove(_ targets: [OptimizeLaunchAgent]) {
        let model = app.optimize
        let app = app
        Task {
            let (items, stopped) = await model.prepareRemoval(targets)
            guard !items.isEmpty else { return }
            // Outro módulo abriu uma confirmação enquanto os agentes paravam: não passa por cima dela.
            guard app.removalRequest == nil else {
                await model.removalSheetClosed()
                return
            }
            let title = items.count == 1
                ? "Remover o agente “\(items[0].label ?? items[0].url.lastPathComponent)”?"
                : "Remover \(items.count) agentes?"
            var note = "Só o arquivo .plist sai; o app em si não é tocado."
            if stopped > 0 {
                note += stopped == 1
                    ? " O agente já foi parado; se você cancelar, ele volta a ser carregado."
                    : " Os agentes já foram parados; se você cancelar, voltam a ser carregados."
            }
            app.requestRemoval(items, source: Feature.optimize.title, title: title, note: note) { report in
                model.finishRemoval(report)
            }
            selection.subtract(targets.map(\.id))
            // Espera a folha fechar mesmo que você saia desta tela. Se fechou sem concluir (Cancelar),
            // os agentes parados voltam a carregar; se concluiu, `finishRemoval` já cuidou deles.
            if let requestID = app.removalRequest?.id {
                await OptimizeSheetWatcher.waitUntilClosed(requestID, in: app)
            }
            await model.removalSheetClosed()
        }
    }
}

private struct OptimizeGroupHeader: View {
    let scope: OptimizeAgentScope
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(scope.title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            if !scope.isManageable {
                Label("requer administrador", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("O CleanerCRTV só mostra estes itens. Para mexer neles, use o Finder com a senha de administrador.")
            }
        }
    }
}

private struct OptimizeAgentRow: View {
    let agent: OptimizeLaunchAgent
    let isBusy: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            control
                .frame(width: 40)

            icon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if agent.owner != nil {
                        Text(agent.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(agent.program ?? agent.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(agent.program ?? agent.url.path)
                if let problem = agent.problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Brand.red)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(agent.scheduleDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 90, alignment: .trailing)

            tags
        }
        .padding(.vertical, 4)
        .opacity(agent.isDisabled && !agent.isBroken ? 0.65 : 1)
        .contentShape(.rect)
    }

    @ViewBuilder private var control: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else if agent.isManageable {
            Toggle("Ativo", isOn: Binding(get: { agent.isEnabled }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(agent.isEnabled ? "Desativar: para agora e não abre mais sozinho" : "Ativar e carregar agora")
                .accessibilityLabel("\(agent.isEnabled ? "Desativar" : "Ativar") \(agent.displayName)")
        } else {
            Image(systemName: "lock.fill")
                .foregroundStyle(.tertiary)
                .help(agent.scope.isManageable ? "Arquivo inválido: não dá para ativar ou desativar" : "Requer administrador")
                .accessibilityLabel("Somente leitura")
        }
    }

    @ViewBuilder private var icon: some View {
        Group {
            if let owner = agent.owner {
                FileIcon(url: owner.url, size: 30)
            } else {
                Image(systemName: agent.scope == .systemDaemon ? "gearshape.2.fill" : "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.gray.gradient))
            }
        }
        .frame(width: 30, height: 30)
        .overlay(alignment: .bottomTrailing) {
            if agent.isBroken {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white, Brand.red)
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var tags: some View {
        HStack(spacing: 4) {
            if agent.isBroken { OptimizeTag(text: "Quebrado", color: Brand.red) }
            if agent.isRunning {
                OptimizeTag(text: "Em execução", color: Brand.green)
                    .help(agent.pid.map { "PID \($0)" } ?? "")
            } else if agent.isLoaded {
                OptimizeTag(text: "Carregado", color: Brand.teal)
            }
            if !agent.scope.isManageable {
                if agent.isDisabled { OptimizeTag(text: "Desativado", color: .gray) }
                OptimizeTag(text: "Sistema", color: .gray)
            }
        }
        .frame(minWidth: 150, alignment: .trailing)
    }
}

/// Etiqueta curta em cápsula (Quebrado, Carregado, Sistema…).
struct OptimizeTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}

/// Espera a folha de remoção com este pedido sair da tela, sem consultar em laço.
@MainActor
private enum OptimizeSheetWatcher {
    static func waitUntilClosed(_ requestID: UUID, in app: AppModel) async {
        while app.removalRequest?.id == requestID {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = app.removalRequest?.id
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
