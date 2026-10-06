import CleanerCore
import SwiftUI

/// Faixa no topo pedindo Acesso Total ao Disco.
struct FullDiskAccessBanner: View {
    @Environment(\.appModel) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(Brand.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Conceda o Acesso Total ao Disco").font(.callout.weight(.semibold))
                Text("Sem ele, caches de apps, Mail e Safari ficam invisíveis para a varredura.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Já concedi") { model.refreshPermissions() }
                .buttonStyle(.borderless)
            Button("Abrir Ajustes") { model.openFullDiskAccessSettings() }
                .buttonStyle(.tinted(Brand.orange))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Brand.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Aviso flutuante de resultado.
struct ToastView: View {
    let toast: Toast
    @Environment(\.appModel) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.isError ? Brand.orange : Brand.green)
            Text(toast.text)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Button {
                withAnimation(Motion.standard) { model.toast = nil }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 640)
    }
}
