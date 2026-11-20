import SwiftUI

@main
struct ServerModulesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    @State private var push = PushManager.shared

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
        .task {
            push.settings = settings
            push.launch()
        }
        // A new notifier address or login: tell it about this iPhone again.
        .onChange(of: settings.revision) { Task { await push.upload() } }
        .sheet(item: Binding(get: { push.openAlertID.map(OpenAlert.init) },
                             set: { push.openAlertID = $0?.id })) { open in
            NavigationStack {
                Group {
                    if let client = settings.client(.notifier) {
                        NotifierAlertView(client: client, alertID: open.id)
                    } else {
                        ContentUnavailableView("Alerts isn't set up", systemImage: "bell.badge",
                                               description: Text("Set up Alerts (notifier) in Settings."))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { push.openAlertID = nil }
                    }
                }
            }
        }
    }

    /// The alert a tapped notification points to.
    private struct OpenAlert: Identifiable {
        let id: Int
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
        case .notifier: ModuleRoot(kind: kind) { NotifierView(client: $0) }
        }
    }
}
