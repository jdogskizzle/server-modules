import SwiftUI
import UserNotifications

// MARK: - Models (notifier: Grafana alerts, their history, and APNs pushes)

struct NotifierAlert: Decodable, Identifiable {
    let id: Int
    let fingerprint: String?
    /// firing or resolved
    let status: String
    let alertname: String?
    /// critical or warning
    let severity: String?
    let summary: String?
    let description: String?
    let labels: [String: String]?
    let values: [String: JSONValue]?
    let startsAt: String?
    let endsAt: String?
    let dashboardUrl: String?
    let panelUrl: String?
    let silenceUrl: String?
    let updated: String?

    enum CodingKeys: String, CodingKey {
        case id, fingerprint, status, alertname, severity, summary, description, labels, values, updated
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case dashboardUrl = "dashboard_url"
        case panelUrl = "panel_url"
        case silenceUrl = "silence_url"
    }

    var title: String { summary ?? alertname ?? "Alert \(id)" }
    var firing: Bool { status == "firing" }
    /// The panel if there is one, else the dashboard.
    var dashboardLink: URL? { (panelUrl ?? dashboardUrl).flatMap(URL.init(string:)) }

    var severityColor: Color { Notifier.color(severity) }
}

struct NotifierSummary: Decodable {
    let firing: Int
    let firingBySeverity: [String: Int]?
    let latest: NotifierAlert?
    /// on, or off until the server has its APNs key
    let push: String?
    let devices: Int?

    enum CodingKeys: String, CodingKey {
        case firing, latest, push, devices
        case firingBySeverity = "firing_by_severity"
    }

    var critical: Int { firingBySeverity?["critical"] ?? 0 }
}

struct NotifierAlerts: Decodable {
    let alerts: [NotifierAlert]
}

struct NotifierDevices: Decodable {
    struct Device: Decodable, Identifiable {
        let tokenPrefix: String
        let environment: String?
        let name: String?
        let created: JSONValue?
        let lastOk: JSONValue?
        let lastError: String?
        var id: String { tokenPrefix }

        enum CodingKeys: String, CodingKey {
            case environment, name, created
            case tokenPrefix = "token_prefix"
            case lastOk = "last_ok"
            case lastError = "last_error"
        }
    }
    let devices: [Device]
}

struct NotifierTestReply: Decodable {
    struct Result: Decodable {
        let token: String?
        let ok: Bool
        let status: Int?
        let reason: String?
    }
    let results: [Result]
}

enum Notifier {
    static func color(_ severity: String?) -> Color {
        switch severity {
        case "critical": return .red
        case "warning": return .orange
        default: return .secondary
        }
    }

    /// ISO 8601 times (UTC) as a short local date and time.
    static func time(_ iso: String?) -> String {
        guard let d = DVR.date(iso) else { return iso ?? "–" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    /// How long ago, e.g. "12m ago".
    static func ago(_ iso: String?) -> String {
        guard let d = DVR.date(iso) else { return "" }
        return Format.ago(d.timeIntervalSince1970)
    }

    static func duration(_ from: String?, _ to: String?) -> String? {
        guard let a = DVR.date(from), let b = DVR.date(to) else { return nil }
        return Format.duration(b.timeIntervalSince(a))
    }
}

// MARK: - Store

@MainActor @Observable
final class NotifierStore {
    let client: APIClient
    var summary: NotifierSummary?
    var firing: [NotifierAlert]?
    var resolved: [NotifierAlert] = []
    var moreResolved = false
    var error: String?

    private static let page = 50

    init(client: APIClient) { self.client = client }

    func refresh() async {
        do {
            summary = try await client.get("api/summary", as: NotifierSummary.self)
            firing = try await client.get("api/alerts", query: [
                URLQueryItem(name: "status", value: "firing"), URLQueryItem(name: "limit", value: "100"),
            ], as: NotifierAlerts.self).alerts
            let recent = try await client.get("api/alerts", query: [
                URLQueryItem(name: "status", value: "resolved"), URLQueryItem(name: "limit", value: String(Self.page)),
            ], as: NotifierAlerts.self).alerts
            resolved = recent
            moreResolved = recent.count == Self.page
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The next page of resolved alerts, older than the oldest shown.
    func loadMore() async {
        guard let oldest = resolved.map(\.id).min() else { return }
        do {
            let older = try await client.get("api/alerts", query: [
                URLQueryItem(name: "status", value: "resolved"), URLQueryItem(name: "limit", value: String(Self.page)),
                URLQueryItem(name: "before_id", value: String(oldest)),
            ], as: NotifierAlerts.self).alerts
            resolved += older
            moreResolved = older.count == Self.page
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Alerts list

struct NotifierView: View {
    @State private var store: NotifierStore

    init(client: APIClient) {
        _store = State(initialValue: NotifierStore(client: client))
    }

    var body: some View {
        List {
            if let e = store.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if let s = store.summary, s.push == "off" {
                Section {
                    Label("Push is off on the server until its APNs key is installed.", systemImage: "bell.slash")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            if let firing = store.firing {
                Section("Firing") {
                    if firing.isEmpty {
                        Label("All clear", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    ForEach(firing) { row($0) }
                }
                Section("Recent") {
                    if store.resolved.isEmpty {
                        Text("No resolved alerts yet.").foregroundStyle(.secondary)
                    }
                    ForEach(store.resolved) { row($0) }
                    if store.moreResolved {
                        Button("Show older") { Task { await store.loadMore() } }
                    }
                }
            } else if store.error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Alerts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NotifierSettingsView(client: store.client, summary: store.summary)
                } label: {
                    Image(systemName: "bell.badge")
                }
            }
        }
        .refreshable { await store.refresh() }
        .polling(every: 30) { await store.refresh() }
    }

    private func row(_ a: NotifierAlert) -> some View {
        NavigationLink {
            NotifierAlertView(client: store.client, alertID: a.id, initial: a)
        } label: {
            NotifierAlertRow(alert: a)
        }
    }
}

struct NotifierAlertRow: View {
    let alert: NotifierAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Badge(text: alert.severity ?? "alert", color: alert.severityColor)
                Text(alert.title).font(.body.weight(.semibold)).lineLimit(2)
            }
            if let d = alert.description, !d.isEmpty {
                Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(alert.firing
                 ? "Since \(Notifier.time(alert.startsAt)) · \(Notifier.ago(alert.startsAt))"
                 : "\(Notifier.time(alert.startsAt)) – \(Notifier.time(alert.endsAt))"
                   + (Notifier.duration(alert.startsAt, alert.endsAt).map { " (\($0))" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - One alert

struct NotifierAlertView: View {
    @Environment(ServerSettings.self) private var settings
    let client: APIClient
    let alertID: Int
    @State private var alert: NotifierAlert?
    @State private var error: String?

    init(client: APIClient, alertID: Int, initial: NotifierAlert? = nil) {
        self.client = client
        self.alertID = alertID
        _alert = State(initialValue: initial)
    }

    var body: some View {
        Group {
            if let a = alert {
                content(a)
            } else if let error {
                ContentUnavailableView {
                    Label("Can't load the alert", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(alert?.alertname ?? "Alert")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            alert = try await client.get("api/alerts/\(alertID)", as: NotifierAlert.self)
            error = nil
        } catch is CancellationError {
        } catch {
            if alert == nil { self.error = error.localizedDescription }
        }
    }

    private func content(_ a: NotifierAlert) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Badge(text: a.severity ?? "alert", color: a.severityColor)
                        Badge(text: a.status, color: a.firing ? a.severityColor : .green)
                    }
                    Text(a.title).font(.title3.weight(.semibold))
                    if let d = a.description, !d.isEmpty { Text(d).font(.callout) }
                }
                .padding(.vertical, 4)
                LabeledContent("Started", value: Notifier.time(a.startsAt))
                if !a.firing {
                    LabeledContent("Resolved", value: Notifier.time(a.endsAt))
                    if let d = Notifier.duration(a.startsAt, a.endsAt) { LabeledContent("Lasted", value: d) }
                }
                if let n = a.alertname { LabeledContent("Rule", value: n) }
            }
            if a.dashboardLink != nil || a.silenceUrl != nil {
                Section {
                    if let url = a.dashboardLink {
                        NavigationLink {
                            dashboard(url, title: "Dashboard")
                        } label: {
                            Label(a.panelUrl != nil ? "Open the panel" : "Open dashboard", systemImage: "chart.xyaxis.line")
                        }
                    }
                    if let s = a.silenceUrl, let url = URL(string: s) {
                        NavigationLink {
                            dashboard(url, title: "Silence")
                        } label: {
                            Label("Silence in Grafana", systemImage: "bell.slash")
                        }
                    }
                }
            }
            if let values = a.values, !values.isEmpty {
                Section("Values") {
                    ForEach(values.keys.sorted(), id: \.self) { k in
                        LabeledContent(k, value: values[k]?.string ?? "–")
                    }
                }
            }
            if let labels = a.labels, !labels.isEmpty {
                Section("Labels") {
                    ForEach(labels.keys.sorted(), id: \.self) { k in
                        LabeledContent(k, value: labels[k] ?? "")
                    }
                }
            }
        }
    }

    /// Grafana links open in the Dashboards module's web view (signed in) when it's set up,
    /// otherwise in Safari.
    @ViewBuilder
    private func dashboard(_ url: URL, title: String) -> some View {
        if let grafana = settings.client(.grafana) {
            ServiceWebPage(client: grafana, title: title, probePath: "api/search", absoluteURL: url)
        } else {
            ContentUnavailableView {
                Label("Dashboards isn't set up", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Set up Dashboards (Grafana) in Settings to open dashboards here, signed in.")
            } actions: {
                Link("Open in Safari", destination: url)
            }
        }
    }
}

// MARK: - Notification settings

struct NotifierSettingsView: View {
    let client: APIClient
    let summary: NotifierSummary?
    @State private var push = PushManager.shared
    @State private var devices: [NotifierDevices.Device]?
    @State private var iosStatus: UNAuthorizationStatus?
    @State private var testResult: String?
    @State private var testing = false
    @State private var switching = false

    var body: some View {
        List {
            Section {
                Toggle("Notifications on this iPhone", isOn: Binding(
                    get: { push.enabled },
                    set: { on in
                        switching = true
                        Task {
                            if on { await push.enable() } else { await push.disable() }
                            await refresh()
                            switching = false
                        }
                    }))
                    .disabled(switching)
                if let e = push.error {
                    Text(e).font(.callout).foregroundStyle(.red)
                }
                if push.enabled {
                    LabeledContent("Registered with notifier", value: push.registeredAt.map {
                        $0.formatted(date: .omitted, time: .shortened)
                    } ?? (push.token == nil ? "waiting for iOS" : "not yet"))
                }
                if iosStatus == .denied {
                    Text("Notifications are off for this app in iOS Settings → Notifications → Server Modules.")
                        .font(.callout).foregroundStyle(.orange)
                }
            } footer: {
                Text("Critical alerts are time-sensitive, so they come through Focus. Resolved alerts arrive quietly.")
            }

            Section {
                LabeledContent("Push from the server", value: (push.serverPush ?? summary?.push) == "on" ? "On" : "Off")
                if (push.serverPush ?? summary?.push) == "off" {
                    Text("notifier needs its APNs key before it can send anything.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack {
                        Text("Send test notification")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing)
                if let testResult {
                    Text(testResult).font(.callout)
                }
            } header: {
                Text("Server")
            }

            if let devices {
                Section("Devices") {
                    if devices.isEmpty {
                        Text("No devices registered.").foregroundStyle(.secondary)
                    }
                    ForEach(devices) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(d.name ?? "Device")
                                if let t = push.token, t.hasPrefix(d.tokenPrefix) { Badge(text: "this iPhone", color: .blue) }
                                Spacer()
                                Text(d.environment ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            if let e = d.lastError, !e.isEmpty {
                                Text(e).font(.caption).foregroundStyle(.red)
                            } else if let ok = d.lastOk?.string {
                                Text("Last push delivered \(DVR.date(ok).map { Format.ago($0.timeIntervalSince1970) } ?? ok)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    private func refresh() async {
        iosStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        devices = (try? await client.get("api/devices", as: NotifierDevices.self))?.devices
    }

    private func sendTest() async {
        if (push.serverPush ?? summary?.push) == "off" {
            testResult = "Push is off on the server: notifier needs its APNs key first."
            return
        }
        testing = true
        defer { testing = false }
        do {
            let reply: NotifierTestReply = try await client.fetch("POST", "api/test")
            if reply.results.isEmpty {
                testResult = "No devices to send to. Turn on notifications above first."
            } else {
                testResult = reply.results.map { r in
                    "\(r.token ?? "device"): " + (r.ok ? "sent" : "failed\(r.reason.map { " (\($0))" } ?? "")")
                }.joined(separator: "\n")
            }
        } catch {
            let message = error.localizedDescription
            testResult = message.contains("409")
                ? "Push is off on the server: notifier needs its APNs key first."
                : "Couldn't send: \(message)"
        }
    }
}
