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
    @AppStorage("selectedTab") private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "square.grid.2x2") }
                .tag("home")
            ForEach(settings.pinnedTabs) { kind in
                NavigationStack { ServiceScreen(kind: kind) }
                    .tabItem { Label(kind.title, systemImage: kind.systemImage) }
                    .tag(kind.rawValue)
            }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .onAppear(perform: keepTabValid)
        .onChange(of: settings.tabSlots) { keepTabValid() }
    }

    /// Back to Home when the selected tab no longer exists (unpinned, or from an older version).
    private func keepTabValid() {
        let valid = ["home", "settings"] + settings.pinnedTabs.map(\.rawValue)
        if !valid.contains(tab) { tab = "home" }
    }
}

/// One service's full screen, or a prompt to set it up.
struct ServiceScreen: View {
    let kind: ServerKind

    var body: some View {
        switch kind {
        case .miner: ModuleRoot(kind: kind) { MinerView(client: $0) }
        case .musicflow: ModuleRoot(kind: kind) { MusicFlowView(client: $0) }
        case .mcpanel: ModuleRoot(kind: kind) { MCPanelView(client: $0) }
        case .ledger: ModuleRoot(kind: kind) { LedgerView(client: $0) }
        case .grafana: ModuleRoot(kind: kind) { GrafanaView(client: $0) }
        case .admute: ModuleRoot(kind: kind) { AdmuteView(client: $0) }
        case .dvr: ModuleRoot(kind: kind) { DVRView(client: $0) }
        }
    }
}
