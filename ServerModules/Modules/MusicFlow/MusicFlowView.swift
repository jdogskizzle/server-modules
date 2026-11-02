import SwiftUI

@MainActor @Observable
final class MusicFlowStore {
    let client: APIClient
    var overview: MFOverview?
    var jobs: MFJobs?
    var disk: MFDisk?
    var error: String?
    var notice: String?

    init(client: APIClient) { self.client = client }

    func refreshOverview() async {
        await load { self.overview = try await self.client.get("api/overview") }
    }

    func refreshJobs() async {
        await load { self.jobs = try await self.client.get("api/jobs") }
    }

    func refreshDisk() async {
        // Disk usage is a nice-to-have; don't show an error for it.
        disk = try? await client.get("api/disk")
    }

    private func load(_ op: () async throws -> Void) async {
        do {
            try await op()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Runs an action; on failure shows its error. Returns whether it worked.
    @discardableResult
    func perform(_ success: String? = nil, _ op: () async throws -> Void) async -> Bool {
        do {
            try await op()
            error = nil
            if let success { notice = success }
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func setFormat(_ f: String) async {
        await perform { try await self.client.send("POST", "api/settings", body: ["format": .string(f)]) }
        await refreshOverview()
    }

    func jobAction(_ id: String, _ action: String) async {
        await perform { try await self.client.send("POST", "api/jobs/\(APIClient.segment(id))/\(action)") }
        await refreshJobs()
    }

    func clearFinished() async {
        await perform { try await self.client.send("POST", "api/jobs/clear") }
        await refreshJobs()
    }

    func scanJellyfin() async {
        await perform("Jellyfin scan started") { try await self.client.send("POST", "api/jellyfin") }
    }

    func refreshLidarr() async {
        await perform { try await self.client.send("POST", "api/refresh") }
        await refreshOverview()
    }
}

struct MusicFlowView: View {
    @State private var store: MusicFlowStore
    @State private var query = ""
    @AppStorage("musicflow.onlyMissing") private var onlyMissing = true

    init(client: APIClient) {
        _store = State(initialValue: MusicFlowStore(client: client))
    }

    var body: some View {
        Group {
            List {
                if let e = store.error {
                    Section { ErrorBanner(message: e) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if let o = store.overview {
                    links(o)
                    storage
                    artists(o)
                } else if store.error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Music")
            .navigationDestination(for: MFArtistSummary.self) { a in
                MFArtistView(store: store, artistId: a.id, name: a.name)
            }
            .searchable(text: $query, prompt: "Artists")
            .toolbar { toolbar }
            .refreshable {
                await store.refreshOverview()
                await store.refreshDisk()
            }
            .polling(every: 15) {
                await store.refreshOverview()
                await store.refreshDisk()
            }
            .noticeAlert($store.notice)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let o = store.overview {
                    Picker("Wanted format", selection: Binding(
                        get: { o.format },
                        set: { f in Task { await store.setFormat(f) } })) {
                        ForEach(formatKeys(o), id: \.self) { key in
                            Text(o.formats[key] ?? key).tag(key)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section {
                    Toggle("Only artists with gaps", isOn: $onlyMissing)
                    Button {
                        Task { await store.refreshLidarr() }
                    } label: {
                        Label("Reload from Lidarr", systemImage: "arrow.clockwise")
                    }
                    if store.overview?.jellyfin == true {
                        Button {
                            Task { await store.scanJellyfin() }
                        } label: {
                            Label("Scan Jellyfin music", systemImage: "play.tv")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func links(_ o: MFOverview) -> some View {
        Section {
            NavigationLink {
                MFActivityView(store: store)
            } label: {
                Label("Activity", systemImage: "arrow.down.circle")
            }
            .badge(o.activeJobs)
            NavigationLink {
                MFImportView(store: store)
            } label: {
                Label("Import from downloads", systemImage: "tray.and.arrow.down")
            }
            if let w = o.worker, !w.running, let note = w.note, !note.isEmpty {
                Label("Downloads paused: \(note)", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if o.slskd == false {
                Label("No slskd API key set, so searching is off", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("Wanted format: \(o.formats[o.format] ?? o.format)")
        }
    }

    @ViewBuilder
    private var storage: some View {
        if let drives = store.disk?.drives, !drives.isEmpty {
            Section("Storage") {
                ForEach(drives) { d in
                    let used = max(d.total - d.free, 0)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(d.label)
                            Spacer()
                            Text("\(Format.bytes(d.free)) free of \(Format.bytes(d.total))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: used, total: max(d.total, 1))
                            .tint(driveColor(free: d.free, usedFraction: used / max(d.total, 1)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artists(_ o: MFOverview) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = o.artists.filter { a in
            (q.isEmpty || a.name.localizedCaseInsensitiveContains(q))
                && (!onlyMissing || !q.isEmpty || a.missing > 0 || a.active > 0)
        }
        Section {
            if shown.isEmpty {
                Text(onlyMissing ? "No artists with missing albums." : "No artists.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { a in
                NavigationLink(value: a) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(a.name)
                            if a.active > 0 { Badge(text: "\(a.active) in progress", color: .blue) }
                        }
                        Text(summary(a)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Artists")
        } footer: {
            if onlyMissing && q.isEmpty {
                Text("Showing artists with missing albums. Change this in the ⋯ menu.")
            }
        }
    }

    private func driveColor(free: Double, usedFraction: Double) -> Color {
        if free < 20e9 || usedFraction > 0.95 { return .red }
        if free < 60e9 || usedFraction > 0.85 { return .orange }
        return .accentColor
    }

    private func formatKeys(_ o: MFOverview) -> [String] {
        let known = MF.formatOrder.filter { o.formats[$0] != nil }
        let other = o.formats.keys.filter { !MF.formatOrder.contains($0) }.sorted()
        return known + other
    }

    private func summary(_ a: MFArtistSummary) -> String {
        var parts = ["\(a.have)/\(a.total) albums"]
        if a.missing > 0 { parts.append("\(a.missing) missing") }
        if a.partial > 0 { parts.append("\(a.partial) partial") }
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// Shows a short message (e.g. "Added 3 downloads") as an alert, then clears it.
    func noticeAlert(_ notice: Binding<String?>) -> some View {
        alert(notice.wrappedValue ?? "", isPresented: Binding(
            get: { notice.wrappedValue != nil },
            set: { if !$0 { notice.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
