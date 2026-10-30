import SwiftUI

@main
struct ServerModulesApp: App {
    @State private var settings = ServerSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
    }
}

struct RootView: View {
    @Environment(ServerSettings.self) private var settings
    @AppStorage("selectedTab") private var tab = ServerKind.miner.rawValue

    var body: some View {
        TabView(selection: $tab) {
            ForEach(settings.enabledKinds) { kind in
                module(kind)
                    .tabItem { Label(kind.title, systemImage: kind.systemImage) }
                    .tag(kind.rawValue)
            }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .onAppear {
            if tab != "settings", !settings.enabledKinds.map(\.rawValue).contains(tab) {
                tab = settings.enabledKinds.first?.rawValue ?? "settings"
            }
        }
    }

    @ViewBuilder
    private func module(_ kind: ServerKind) -> some View {
        switch kind {
        case .miner: ModuleRoot(kind: kind) { MinerView(client: $0) }
        case .musicflow: ModuleRoot(kind: kind) { MusicFlowView(client: $0) }
        case .mcpanel: ModuleRoot(kind: kind) { MCPanelView(client: $0) }
        case .ledger: ModuleRoot(kind: kind) { LedgerView(client: $0) }
        }
    }
}
