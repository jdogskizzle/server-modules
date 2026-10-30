import SwiftUI

@MainActor @Observable
final class MCPanelStore {
    let client: APIClient
    var servers: MCServers?
    var jobs: [MCJob] = []
    var error: String?
    var notice: String?

    init(client: APIClient) { self.client = client }

    func refresh() async {
        do {
            let s: MCServers = try await client.get("api/servers")
            let j: [MCJob] = try await client.get("api/jobs")
            servers = s
            jobs = j
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func server(_ name: String) -> MCServer? { servers?.servers.first { $0.name == name } }

    /// Starts a background job on the panel. Returns it, or nil on error.
    @discardableResult
    func startJob(_ path: String, body: JSONValue = [:]) async -> MCJob? {
        do {
            let job: MCJob = try await client.fetch("POST", path, body: body)
            error = nil
            await refresh()
            return job
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func action(_ server: String, _ action: String) async {
        await startJob("api/servers/\(APIClient.segment(server))/\(action)")
    }
}

struct MCPanelView: View {
    @State private var store: MCPanelStore
    @State private var adding = false

    init(client: APIClient) {
        _store = State(initialValue: MCPanelStore(client: client))
    }

    var body: some View {
        NavigationStack {
            List {
                if let e = store.error {
                    Section { ErrorBanner(message: e) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if let s = store.servers {
                    Section {
                        if s.servers.isEmpty {
                            Text("No servers yet. Add one with +.").foregroundStyle(.secondary)
                        }
                        ForEach(s.servers) { srv in
                            NavigationLink(value: srv.name) { MCServerRow(server: srv) }
                        }
                    } footer: {
                        if let t = s.updated, t > 0 { Text("Status from \(Format.ago(t))") }
                    }
                    let running = store.jobs.filter { $0.status == "running" }
                    Section {
                        NavigationLink {
                            MCJobsView(store: store, server: nil)
                        } label: {
                            Label("Tasks", systemImage: "list.bullet.rectangle")
                        }
                        .badge(running.count)
                    }
                } else if store.error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Minecraft")
            .navigationDestination(for: String.self) { name in
                MCServerDetailView(store: store, name: name)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack { MCAddServerView(store: store) }
            }
            .refreshable { await store.refresh() }
            .polling(every: 5) { await store.refresh() }
            .noticeAlert($store.notice)
        }
    }
}

struct MCServerRow: View {
    let server: MCServer

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: server.status.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(server.name).font(.body.weight(.semibold))
                    if server.busy { ProgressView().controlSize(.mini) }
                }
                Text("\(server.config.typeLabel) \(server.status.runningVersion ?? server.config.versionText) · port \(server.config.port.map(String.init) ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(server.status.label)
                    if let p = server.status.players, let m = server.status.maxPlayers {
                        Label("\(p)/\(m)", systemImage: "person.2.fill")
                    }
                    if let cpu = server.status.cpu { Text("CPU \(cpu)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct MCServerDetailView: View {
    let store: MCPanelStore
    let name: String
    @State private var confirmAction: String?
    @State private var restoreBackup: MCBackup?
    @State private var changing = false

    var body: some View {
        Group {
            if let s = store.server(name) {
                content(s)
            } else {
                ContentUnavailableView("Server not found", systemImage: "cube")
            }
        }
        .navigationTitle(name)
        .refreshable { await store.refresh() }
        .polling(every: 4) { await store.refresh() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }),
                            titleVisibility: .visible, presenting: confirmAction) { action in
            Button(Format.capitalized(action), role: action == "stop" ? .destructive : nil) {
                Task { await store.action(name, action) }
            }
        } message: { action in
            if let p = store.server(name)?.status.players, p > 0 {
                Text("\(p) player\(p == 1 ? " is" : "s are") online.")
            }
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoreBackup != nil }, set: { if !$0 { restoreBackup = nil } }),
                            titleVisibility: .visible, presenting: restoreBackup) { b in
            Button("Restore \(Format.time(b.time))", role: .destructive) {
                Task { await store.startJob("api/servers/\(APIClient.segment(name))/restore", body: ["file": .string(b.file)]) }
            }
        } message: { _ in
            Text("The server stops, its current files are moved aside (kept in the panel's safety folder), and the backup is put in their place.")
        }
        .sheet(isPresented: $changing) {
            if let s = store.server(name) {
                NavigationStack { MCVersionView(store: store, server: s) }
            }
        }
    }

    private var confirmTitle: String {
        guard let a = confirmAction else { return "" }
        return "\(Format.capitalized(a)) \(name)?"
    }

    private func content(_ s: MCServer) -> some View {
        List {
            if let e = store.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                HStack(spacing: 12) {
                    StatusDot(color: s.status.color)
                    VStack(alignment: .leading) {
                        Text(s.status.label).font(.headline)
                        if let d = s.status.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if s.busy { ProgressView() }
                }
                if s.status.isUp {
                    LabeledContent("Players", value: s.status.players.map { "\($0) / \(s.status.maxPlayers ?? 0)" } ?? "–")
                    LabeledContent("Version", value: s.status.runningVersion ?? "–")
                    LabeledContent("CPU", value: s.status.cpu ?? "–")
                    LabeledContent("Memory", value: s.status.memory ?? "–")
                }
            }

            Section {
                if s.status.isUp {
                    Button { confirmAction = "restart" } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { confirmAction = "stop" } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { Task { await store.action(name, "start") } } label: { Label("Start", systemImage: "play.fill") }
                }
                Button { Task { await store.action(name, "backup") } } label: {
                    Label("Back up now", systemImage: "externaldrive.badge.plus")
                }
            } footer: {
                if s.busy { Text("A task is running on this server; wait for it to finish.") }
            }
            .disabled(s.busy)

            Section("Settings") {
                LabeledContent("Type", value: s.config.typeLabel)
                LabeledContent(s.config.type == "CUSTOM" ? "Jar" : "Version", value: s.config.versionText)
                LabeledContent("Java", value: MC.javaLabel(s.config.java ?? "java25"))
                LabeledContent("Memory", value: s.config.memory?.string ?? "–")
                LabeledContent("Port", value: s.config.port.map(String.init) ?? "–")
                if let b = s.config.bedrockPort { LabeledContent("Bedrock port", value: String(b)) }
                LabeledContent("Pause when empty", value: s.config.autopause == true ? "On" : "Off")
                Toggle("Start at boot", isOn: Binding(
                    get: { s.config.autostart ?? true },
                    set: { on in
                        Task { await store.startJob("api/servers/\(APIClient.segment(name))/autostart", body: ["enabled": .bool(on)]) }
                    }))
                    .disabled(s.busy)
                Button("Change type, version, Java or memory…") { changing = true }
                    .disabled(s.busy)
            }

            Section {
                if s.backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                ForEach(s.backups) { b in
                    Button {
                        restoreBackup = b
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(Format.time(b.time)).foregroundStyle(.primary)
                                Text(b.file).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(Format.bytes(b.size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(s.busy)
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("Tap a backup to restore it.")
            }

            let recent = store.jobs.filter { $0.server == name }.prefix(5)
            if !recent.isEmpty {
                Section {
                    ForEach(Array(recent)) { j in
                        NavigationLink {
                            MCJobDetailView(store: store, jobId: j.id)
                        } label: {
                            MCJobRow(job: j, showServer: false)
                        }
                    }
                    NavigationLink("All tasks") { MCJobsView(store: store, server: name) }
                } header: {
                    Text("Recent tasks")
                }
            }
        }
    }
}

// MARK: - Jobs

struct MCJobRow: View {
    let job: MCJob
    var showServer = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(showServer ? "\(job.server): \(job.action)" : Format.capitalized(job.action))
                Spacer()
                if job.status == "running" { ProgressView().controlSize(.mini) }
                Badge(text: job.status, color: job.color)
            }
            Text(job.log.last ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            Text(Format.time(job.started)).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct MCJobsView: View {
    let store: MCPanelStore
    let server: String?

    var body: some View {
        let jobs = store.jobs.filter { server == nil || $0.server == server }
        List {
            if jobs.isEmpty {
                Text("No tasks since the panel started.").foregroundStyle(.secondary)
            }
            ForEach(jobs) { j in
                NavigationLink {
                    MCJobDetailView(store: store, jobId: j.id)
                } label: {
                    MCJobRow(job: j, showServer: server == nil)
                }
            }
        }
        .navigationTitle(server.map { "\($0) tasks" } ?? "Tasks")
        .refreshable { await store.refresh() }
        .polling(every: 3) { await store.refresh() }
    }
}

struct MCJobDetailView: View {
    let store: MCPanelStore
    let jobId: String

    var body: some View {
        Group {
            if let j = store.jobs.first(where: { $0.id == jobId }) {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(j.server): \(j.action)").font(.headline)
                        Spacer()
                        Badge(text: j.status, color: j.color)
                    }
                    .padding()
                    LogView(lines: j.log)
                }
            } else {
                ContentUnavailableView("Task gone", systemImage: "clock",
                                       description: Text("The panel keeps the last 30 tasks, and forgets them when it restarts."))
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .polling(every: 2) { await store.refresh() }
    }
}
