import SwiftUI

struct SettingsView: View {
    @Environment(ServerSettings.self) private var settings

    var body: some View {
        NavigationStack {
            List {
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
                    Text("None of these apps have a login of their own. Reach them over your home network or a VPN (e.g. Tailscale), or through a reverse proxy that asks for a login, and enter that login here.")
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
                Toggle("Show \(kind.title) tab", isOn: $config.enabled)
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
            Section("Login") {
                Picker("Type", selection: $config.auth) {
                    ForEach(AuthMode.allCases) { Text($0.label).tag($0) }
                }
                switch config.auth {
                case .noLogin:
                    EmptyView()
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
        guard let client = ServerSettings.makeClient(config, secret: secret) else {
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
