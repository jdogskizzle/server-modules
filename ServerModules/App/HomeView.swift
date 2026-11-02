import SwiftUI

/// One line about what a service is doing, shown under its name on Home.
struct ServiceSummary: Sendable {
    var text: String
    var tint: Color = .secondary
    /// Something that needs a look (shown as a dot next to the name).
    var alert = false
}

enum SummaryState: Sendable {
    case loaded(ServiceSummary)
    case failed(String)
}

enum Summaries {
    static func load(_ kind: ServerKind, _ c: APIClient) async -> SummaryState {
        do {
            return .loaded(try await fetch(kind, c))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func fetch(_ kind: ServerKind, _ c: APIClient) async throws -> ServiceSummary {
        switch kind {
        case .miner:
            let s = try await c.get("api/status", as: MinerStatus.self)
            let usd = s.live?["miner_est_usd_per_day"]
            switch s.watchdog?.state {
            case "mining":
                return ServiceSummary(text: "Mining \(s.active?.name ?? s.active?.coin ?? "")"
                                      + (usd.map { " · \(Format.usd($0))/day" } ?? ""), tint: .green)
            case "benchmarking": return ServiceSummary(text: "Benchmarking \(s.coinName(s.benchmark?.coin))", tint: .purple)
            case "paused": return ServiceSummary(text: "Paused", tint: .orange)
            case "yielded": return ServiceSummary(text: "Paused for another app", tint: .blue)
            case "cooling": return ServiceSummary(text: "Resuming soon", tint: .blue)
            case "disabled": return ServiceSummary(text: "Turned off")
            case "stopped": return ServiceSummary(text: "Watchdog not running", tint: .red, alert: true)
            default: return ServiceSummary(text: "Waiting for a coin")
            }

        case .musicflow:
            let o = try await c.get("api/overview", as: MFOverview.self)
            if o.activeJobs > 0 { return ServiceSummary(text: "\(o.activeJobs) in progress", tint: .blue) }
            let missing = o.artists.reduce(0) { $0 + $1.missing }
            return ServiceSummary(text: missing > 0 ? "\(missing) albums missing" : "Library complete")

        case .mcpanel:
            let s = try await c.get("api/servers", as: MCServers.self)
            let up = s.servers.filter { $0.status.isUp }
            let players = up.compactMap(\.status.players).reduce(0, +)
            guard !s.servers.isEmpty else { return ServiceSummary(text: "No servers yet") }
            var text = "\(up.count) of \(s.servers.count) running"
            if players > 0 { text += " · \(players) playing" }
            return ServiceSummary(text: text, tint: players > 0 ? .green : .secondary)

        case .ledger:
            let s = try await c.get("api/summary", as: LedgerSummary.self)
            var text = "Fund \(Format.usd(s.fund, cents: false))"
            if s.remaining > 0, s.target > 0 { text += " · \(Format.percent(s.paid / s.target)) paid back" }
            return ServiceSummary(text: text)

        case .grafana:
            let d = try await c.get("api/search", query: [URLQueryItem(name: "type", value: "dash-db")],
                                    as: [GrafanaDashboard].self)
            return ServiceSummary(text: "\(d.count) dashboard\(d.count == 1 ? "" : "s")")

        case .admute:
            let l = try await c.get("api/live", as: AdmuteLive.self)
            if let e = l.error { return ServiceSummary(text: "Proxy unreachable: \(e)", tint: .red, alert: true) }
            let sessions = l.status?.sessions ?? []
            if let m = sessions.first(where: { $0.mutedNow == true }) {
                return ServiceSummary(text: "Muting an ad on \(m.channel) \(m.name ?? "")", tint: .orange)
            }
            if let s = sessions.first {
                return ServiceSummary(text: "Watching \(s.channel) \(s.name ?? "")", tint: .green)
            }
            return ServiceSummary(text: "Idle")

        case .dvr:
            let s = try await c.get("api/status", as: DVRStatus.self)
            let conflict = s.recordings.contains { $0.isActive && $0.conflict != nil }
            let recording = s.recordings.filter { $0.status == "recording" }
            if let r = recording.first {
                let more = recording.count > 1 ? " +\(recording.count - 1)" : ""
                return ServiceSummary(text: "Recording \(r.label)\(more)", tint: .red, alert: conflict)
            }
            if let next = s.recordings.first(where: { $0.status == "scheduled" }) {
                return ServiceSummary(text: "Next: \(next.label), \(DVR.span(next))", alert: conflict)
            }
            return ServiceSummary(text: "Nothing scheduled")
        }
    }
}

struct HomeView: View {
    @Environment(ServerSettings.self) private var settings
    @State private var summaries: [ServerKind: SummaryState] = [:]
    @State private var editing: ServerKind?

    var body: some View {
        NavigationStack {
            List {
                let shown = settings.enabledKinds
                if shown.isEmpty {
                    ContentUnavailableView("No services", systemImage: "square.grid.2x2",
                                           description: Text("Turn on “Show on Home” for a service in Settings."))
                }
                ForEach(ServerKind.groups, id: \.self) { group in
                    let kinds = shown.filter { $0.group == group }
                    if !kinds.isEmpty {
                        Section(group) {
                            ForEach(kinds) { row($0) }
                        }
                    }
                }
            }
            .navigationTitle("Home")
            .navigationDestination(for: ServerKind.self) { ServiceScreen(kind: $0) }
            .refreshable { await loadAll() }
            .polling(every: 30) { await loadAll() }
            .onChange(of: settings.revision) { Task { await loadAll() } }
            .sheet(item: $editing) { kind in
                NavigationStack { ServerEditView(kind: kind) }
            }
        }
    }

    @ViewBuilder
    private func row(_ kind: ServerKind) -> some View {
        if settings.client(kind) == nil {
            Button {
                editing = kind
            } label: {
                label(kind, line: Text("Not set up. Tap to add it.").foregroundStyle(.tertiary), alert: false)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: kind) {
                switch summaries[kind] {
                case .loaded(let s):
                    label(kind, line: Text(s.text).foregroundStyle(s.tint), alert: s.alert)
                case .failed(let e):
                    label(kind, line: Text(e).foregroundStyle(.red), alert: true)
                case nil:
                    label(kind, line: Text("…").foregroundStyle(.tertiary), alert: false)
                }
            }
        }
    }

    private func label<Line: View>(_ kind: ServerKind, line: Line, alert: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.body.weight(.semibold))
                    if alert { Circle().fill(.orange).frame(width: 8, height: 8) }
                }
                line.font(.subheadline).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadAll() async {
        let clients = settings.enabledKinds.compactMap { k in settings.client(k).map { (k, $0) } }
        await withTaskGroup(of: (ServerKind, SummaryState).self) { group in
            for (kind, client) in clients {
                group.addTask { (kind, await Summaries.load(kind, client)) }
            }
            for await (kind, state) in group {
                summaries[kind] = state
            }
        }
    }
}
