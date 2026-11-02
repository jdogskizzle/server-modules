import SwiftUI

/// One result of GET /api/search?type=dash-db.
struct GrafanaDashboard: Decodable, Identifiable, Hashable {
    let uid: String
    let title: String
    let folderTitle: String?
    let tags: [String]?
    let isStarred: Bool?
    var id: String { uid }
}

@MainActor @Observable
final class GrafanaStore {
    let client: APIClient
    var dashboards: [GrafanaDashboard]?
    var error: String?

    init(client: APIClient) { self.client = client }

    func refresh() async {
        do {
            dashboards = try await client.get("api/search", query: [
                URLQueryItem(name: "type", value: "dash-db"), URLQueryItem(name: "limit", value: "5000"),
            ], as: [GrafanaDashboard].self)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GrafanaView: View {
    @State private var store: GrafanaStore
    @State private var query = ""

    init(client: APIClient) {
        _store = State(initialValue: GrafanaStore(client: client))
    }

    var body: some View {
        Group {
            List {
                if let e = store.error {
                    Section { ErrorBanner(message: e) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if let all = store.dashboards {
                    sections(all)
                } else if store.error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Dashboards")
            .navigationDestination(for: GrafanaDashboard.self) { d in
                GrafanaDashboardView(client: store.client, dashboard: d)
            }
            .searchable(text: $query, prompt: "Dashboards")
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
        }
    }

    @ViewBuilder
    private func sections(_ all: [GrafanaDashboard]) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = all.filter { d in
            q.isEmpty || d.title.localizedCaseInsensitiveContains(q)
                || (d.folderTitle ?? "").localizedCaseInsensitiveContains(q)
                || (d.tags ?? []).contains { $0.localizedCaseInsensitiveContains(q) }
        }
        let starred = shown.filter { $0.isStarred == true }
        let folders = Dictionary(grouping: shown) { $0.folderTitle ?? "" }
        let folderNames = folders.keys.sorted { a, b in
            // Dashboards outside a folder ("General") first, then folders A–Z.
            a.isEmpty != b.isEmpty ? a.isEmpty : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }

        if all.isEmpty {
            ContentUnavailableView("No dashboards", systemImage: "chart.xyaxis.line",
                                   description: Text("This Grafana user can't see any dashboards."))
        } else if shown.isEmpty {
            ContentUnavailableView.search(text: q)
        }
        if !starred.isEmpty && q.isEmpty {
            Section("Starred") {
                ForEach(starred) { row($0) }
            }
        }
        ForEach(folderNames, id: \.self) { name in
            Section(name.isEmpty ? "General" : name) {
                ForEach(folders[name] ?? []) { row($0) }
            }
        }
    }

    private func row(_ d: GrafanaDashboard) -> some View {
        NavigationLink(value: d) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(d.title)
                    if d.isStarred == true {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                }
                if let tags = d.tags, !tags.isEmpty {
                    Text(tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One dashboard, shown by Grafana itself in a web view that shares the app's session.
struct GrafanaDashboardView: View {
    let client: APIClient
    let dashboard: GrafanaDashboard
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("grafana.range") private var range = "now-6h"
    @AppStorage("grafana.kiosk") private var kiosk = true
    @State private var cookies: [HTTPCookie]?
    @State private var error: String?
    @State private var reload = 0
    @State private var loading = true

    static let ranges: [(String, String)] = [
        ("now-15m", "Last 15 minutes"), ("now-1h", "Last hour"), ("now-6h", "Last 6 hours"),
        ("now-24h", "Last 24 hours"), ("now-7d", "Last 7 days"), ("now-30d", "Last 30 days"),
    ]

    private var url: URL {
        var q = [URLQueryItem(name: "from", value: range), URLQueryItem(name: "to", value: "now"),
                 URLQueryItem(name: "theme", value: colorScheme == .dark ? "dark" : "light"),
                 URLQueryItem(name: "refresh", value: "1m")]
        // Kiosk hides Grafana's menus and header, leaving just the panels.
        if kiosk { q.append(URLQueryItem(name: "kiosk", value: nil)) }
        return client.url("d/\(APIClient.segment(dashboard.uid))", query: q)
    }

    var body: some View {
        Group {
            if let cookies {
                ServiceWebView(url: url, cookies: cookies, reload: reload, loading: $loading)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        if loading { ProgressView().padding(.top, 8) }
                    }
            } else if let error {
                ContentUnavailableView {
                    Label("Can't open the dashboard", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await signIn() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(dashboard.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Time range", selection: $range) {
                        ForEach(Self.ranges, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("Grafana controls", isOn: Binding(get: { !kiosk }, set: { kiosk = !$0 }))
                    Link(destination: client.url("d/\(APIClient.segment(dashboard.uid))")) {
                        Label("Open in Safari", systemImage: "safari")
                    }
                } label: {
                    Image(systemName: "clock")
                }
                Button {
                    reload += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await signIn() }
    }

    /// Makes sure the app's Grafana session is current (signing in again if needed), then
    /// hands its cookies to the web view.
    private func signIn() async {
        error = nil
        do {
            _ = try await client.data("GET", "api/search", query: [URLQueryItem(name: "limit", value: "1")])
            cookies = try await client.webCookies()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
