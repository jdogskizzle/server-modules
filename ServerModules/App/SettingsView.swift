import SwiftUI

struct SettingsView: View {
    @Environment(ServerSettings.self) private var settings

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(0..<ServerSettings.tabSlotCount, id: \.self) { slot in
                        Picker("Tab \(slot + 1)", selection: Binding(
                            get: { settings.tabSlots[slot] },
                            set: { settings.setTab(slot, $0) })) {
                            Text("None").tag(ServerKind?.none)
                            ForEach(ServerKind.allCases) { kind in
                                Label(kind.title, systemImage: kind.systemImage).tag(ServerKind?.some(kind))
                            }
                        }
                    }
                } header: {
                    Text("Tabs")
                } footer: {
                    Text("Up to three services to show as their own tabs, between Home and Settings. They stay on Home too.")
                }
                Section {
                    ForEach(ServerKind.allCases) { kind in
                        NavigationLink {
                            ServerEditView(kind: kind)
                        } label: {
                            row(kind)
                        }
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Each app has its own sign-in page: choose “Sign-in page” and enter the same username and password you use in the browser. The app stays signed in and signs in again when the session runs out.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func row(_ kind: ServerKind) -> some View {
        let c = settings.config(kind)
        return HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(c.baseURL.isEmpty ? "Not set up" : c.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !c.enabled { Badge(text: "Hidden") }
        }
    }
}

struct ServerEditView: View {
    @Environment(ServerSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let kind: ServerKind

    @State private var config = ServerConfig()
    @State private var secret = ""
    @State private var loaded = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        Form {
            Section {
                Toggle("Show on Home", isOn: $config.enabled)
            }
            Section {
                TextField(kind.urlHint, text: $config.baseURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Address")
            } footer: {
                Text(kind.setupNote)
            }
            Section {
                Picker("Type", selection: $config.auth) {
                    ForEach(AuthMode.allCases) { Text($0.label).tag($0) }
                }
                switch config.auth {
                case .noLogin:
                    EmptyView()
                case .form:
                    TextField("Username", text: $config.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $secret)
                        .textContentType(.password)
                case .basic:
                    TextField("Username", text: $config.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $secret)
                        .textContentType(.password)
                case .bearer:
                    SecureField("Token", text: $secret)
                case .header:
                    TextField("Header name", text: $config.headerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Header value", text: $secret)
                }
            } header: {
                Text("Login")
            } footer: {
                switch config.auth {
                case .form: Text(kind == .grafana ? "Grafana's own login. A user that only signs in through single sign-on can't be used here."
                                                  : "The server's own sign-in page (formlogin).")
                case .noLogin: Text("Only if the server's sign-in is turned off (…_AUTH=off).")
                default: Text("For a reverse proxy that asks for a login before the app.")
                }
            }
            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || config.baseURL.isEmpty)
                if let r = testResult {
                    Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.ok ? Color.green : Color.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle(kind.appName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    settings.save(kind, config: config, secret: secret)
                    dismiss()
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            config = settings.config(kind)
            secret = settings.secret(kind)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        guard let client = ServerSettings.makeClient(config, secret: secret, style: kind.loginStyle) else {
            testResult = (false, "That address doesn't look right. Use http://host:port or https://host/path.")
            return
        }
        do {
            _ = try await client.data("GET", kind.probePath)
            testResult = (true, "Connected")
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}
