import AppKit
import CleanerCore
import SwiftUI

/// "Itens de início": lista legada "Abrir ao iniciar sessão", lida pelo Eventos do Sistema.
struct OptimizeLoginItemsPane: View {
    @Environment(\.appModel) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirming: OptimizeLoginItem?

    var body: some View {
        let model = app.optimize
        VStack(spacing: 0) {
            content(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.standard(reduceMotion), value: model.loginItemsState)
            backgroundItemsCard
        }
        .confirmationDialog(
            "Tirar “\(confirming?.name ?? "")” do início?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { item in
            Button("Remover do início") { remove(item) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("O app continua instalado; só deixa de abrir sozinho quando você inicia a sessão.")
        }
    }

    @ViewBuilder
    private func content(_ model: OptimizeModel) -> some View {
        switch model.loginItemsState {
        case .idle:
            ScanHero(symbol: "power.circle", tint: Feature.optimize.tint, title: "Itens de início",
                     message: "Para listar os apps que abrem quando você inicia a sessão, o CleanerCRTV pede ao macOS permissão para usar os Eventos do Sistema. Nada muda sem você mandar.",
                     buttonTitle: "Carregar itens de início") {
                Task { await model.loadLoginItems() }
            }
        case .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Consultando os Eventos do Sistema…").font(.title3.weight(.semibold))
                Text("Se o macOS perguntar, clique em Permitir.")
                    .foregroundStyle(.secondary)
            }
        case .failed(let error):
            ContentUnavailableView {
                Label(error.title, systemImage: error == .notPermitted ? "hand.raised.fill" : "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                HStack {
                    if error == .notPermitted {
                        Button("Abrir Ajustes de Automação") { NSWorkspace.shared.open(OptimizeLoginItems.automationSettingsURL) }
                    }
                    Button("Tentar de novo") { Task { await model.loadLoginItems() } }
                        .buttonStyle(.gradient)
                }
            }
        case .loaded:
            if model.loginItems.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum app abre ao iniciar sessão", systemImage: "checkmark.circle")
                } description: {
                    Text("A lista “Abrir ao iniciar sessão” está vazia. Itens em segundo plano ficam nos Ajustes, logo abaixo.")
                } actions: {
                    Button("Recarregar") { Task { await model.loadLoginItems() } }
                }
            } else {
                loadedList(model)
            }
        }
    }

    private func loadedList(_ model: OptimizeModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.loginItems.count) \(model.loginItems.count == 1 ? "app abre" : "apps abrem") quando você inicia a sessão")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.loadLoginItems() }
                } label: {
                    Label("Recarregar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)

            List(model.loginItems) { item in
                OptimizeLoginItemRow(item: item, isBusy: model.busyLoginItems.contains(item.id)) {
                    confirming = item
                }
                .contextMenu {
                    if let url = item.url {
                        Button("Mostrar no Finder") { Reveal.inFinder(url) }
                        Button("Copiar caminho") { Reveal.copyPath(url) }
                        Divider()
                    }
                    Button("Remover do início…") { confirming = item }
                }
            }
            .listStyle(.inset)
        }
    }

    /// Apps modernos registram itens que só os Ajustes conseguem listar.
    private var backgroundItemsCard: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .font(.title2)
                    .foregroundStyle(Feature.optimize.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Itens em segundo plano").font(.callout.weight(.semibold))
                    Text("O macOS não deixa outros apps listarem tudo o que roda em segundo plano. Os ajudantes que os apps instalam aparecem em Agentes de inicialização; o resto, nos Ajustes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Ver agentes") {
                    withAnimation(Motion.standard(reduceMotion)) { app.optimize.section = .agents }
                }
                Button("Abrir Ajustes ▸ Itens de Início") { NSWorkspace.shared.open(OptimizeLoginItems.settingsURL) }
                    .buttonStyle(.tinted(Feature.optimize.tint))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func remove(_ item: OptimizeLoginItem) {
        let model = app.optimize
        Task {
            if let error = await model.removeLoginItem(item) {
                app.showToast("Não foi possível tirar “\(item.name)” do início: \(error)",
                              symbol: "exclamationmark.triangle.fill", isError: true)
            } else {
                app.showToast("“\(item.name)” não abre mais ao iniciar sessão")
            }
        }
    }
}

private struct OptimizeLoginItemRow: View {
    let item: OptimizeLoginItem
    let isBusy: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = item.url {
                    FileIcon(url: url, size: 30)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).fontWeight(.medium).lineLimit(1)
                Text(item.path ?? "Caminho desconhecido")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if item.isHidden {
                OptimizeTag(text: "Abre oculto", color: .gray)
            }
            if isBusy {
                ProgressView().controlSize(.small).frame(width: 130)
            } else {
                Button("Remover do início", action: onRemove)
                    .controlSize(.small)
                    .frame(width: 130)
            }
        }
        .padding(.vertical, 4)
    }
}
