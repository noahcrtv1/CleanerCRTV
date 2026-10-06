import AppKit
import CleanerCore
import SwiftUI

@main
struct CleanerCRTVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("CleanerCRTV", id: "main") {
            ContentView()
                .environment(\.appModel, model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1220, height: 780)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(\.appModel, model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environment(\.appModel, model)
        } label: {
            MenuBarLabel()
                .environment(\.appModel, model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["showMenuBar": true, "removalMode": RemovalMode.trash.rawValue])
    }

    /// Com o monitor na barra de menus, fechar a janela não encerra o app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBar")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { model?.refreshPermissions() }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Ir") {
            ForEach(Array(Feature.allCases.enumerated()), id: \.element) { index, feature in
                Button(feature.title) {
                    openWindow(id: "main")
                    model.selection = feature
                }
                .keyboardShortcut(index < 9 ? KeyEquivalent(Character(String(index + 1))) : "0", modifiers: .command)
            }
        }
    }
}
