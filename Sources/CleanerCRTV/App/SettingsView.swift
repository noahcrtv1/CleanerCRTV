import CleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Geral", systemImage: "gearshape") }
            ExclusionSettings()
                .tabItem { Label("Ignorar", systemImage: "eye.slash") }
        }
        .frame(width: 520, height: 400)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("removalMode") private var removalMode = RemovalMode.trash.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("skipOpening") private var skipOpening = false

    var body: some View {
        Form {
            Section {
                Picker("Ao limpar", selection: $removalMode) {
                    Text("Mover para a Lixeira (recuperável)").tag(RemovalMode.trash.rawValue)
                    Text("Apagar permanentemente").tag(RemovalMode.permanent.rawValue)
                }
                Text("Cada limpeza ainda pede confirmação, e dá para trocar o modo na hora.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Monitor na barra de menus", isOn: $showMenuBar)
                Toggle("Pular a animação de abertura", isOn: $skipOpening)
            }
            Section("Acesso Total ao Disco") {
                HStack {
                    Image(systemName: model.fullDiskAccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.fullDiskAccess ? Brand.green : Brand.orange)
                    Text(model.fullDiskAccess ? "Concedido" : "Não concedido — parte do lixo fica invisível")
                    Spacer()
                    Button("Abrir Ajustes…") { model.openFullDiskAccessSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExclusionSettings: View {
    @State private var paths = Exclusions.paths
    @State private var selection: String?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pastas que nenhuma varredura vai tocar.")
                .foregroundStyle(.secondary)
            List(paths, id: \.self, selection: $selection) { path in
                Label(path.replacingOccurrences(of: Paths.home.path, with: "~"), systemImage: "folder")
            }
            .listStyle(.bordered)
            HStack {
                Button { importing = true } label: { Image(systemName: "plus") }
                Button {
                    if let selection { Exclusions.remove(selection); paths = Exclusions.paths }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
            }
        }
        .padding(20)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach(Exclusions.add)
                paths = Exclusions.paths
            }
        }
    }
}
