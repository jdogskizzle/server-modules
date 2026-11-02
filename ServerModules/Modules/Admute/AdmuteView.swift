import SwiftUI

// MARK: - Models (admute studio: app/studio.py)

/// GET /api/live: what the admute proxy is doing, and recent mute events.
struct AdmuteLive: Decodable {
    let configured: Bool?
    let status: Status?
    let error: String?
    let events: [String]?

    struct Status: Decodable {
        let delaySeconds: Double?
        let sessions: [Session]
        enum CodingKeys: String, CodingKey {
            case sessions
            case delaySeconds = "delay_seconds"
        }
    }

    /// One open channel.
    struct Session: Decodable, Identifiable {
        let channel: String
        let name: String?
        let viewers: Int?
        let openSeconds: Double?
        let mutedNow: Bool?
        let detectorRunning: Bool?
        let logoLearned: Bool?
        let learningMinutesLeft: Double?
        let logoScore: Double?
        /// "show" or "ad"
        let state: String?
        let armed: Bool?
        let adsMuted: Int?
        var id: String { channel }

        enum CodingKeys: String, CodingKey {
            case channel, name, viewers, state, armed
            case openSeconds = "open_seconds"
            case mutedNow = "muted_now"
            case detectorRunning = "detector_running"
            case logoLearned = "logo_learned"
            case learningMinutesLeft = "learning_minutes_left"
            case logoScore = "logo_score"
            case adsMuted = "ads_muted"
        }
    }

    /// "2026-11-01 20:15:03 4.1 KOMO: ad from 20:14:58" → (time, text).
    static func split(_ line: String) -> (time: String, text: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0].count == 10, parts[1].count == 8 else { return ("", line) }
        return ("\(parts[0]) \(parts[1].prefix(5))", parts[2])
    }
}

struct AdmuteJob: Decodable, Identifiable {
    let id: String
    let kind: String
    let name: String?
    let what: String?
    let title: String?
    /// running, done, failed or stopped
    let state: String
    let started: Double?
    let ended: Double?
    let progress: String?
    let log: String?

    var color: Color {
        switch state {
        case "running": return .blue
        case "done": return .green
        case "failed": return .red
        default: return .secondary
        }
    }
}

struct AdmuteRecordings: Decodable {
    let recordings: [Recording]

    struct Recording: Decodable, Identifiable {
        let name: String
        let title: String
        let size: Double?
        let modified: Double?
        let recording: Bool?
        let surveyed: Bool?
        let labelled: Bool?
        let length: Double?
        let breaks: Int?
        let job: AdmuteJob?
        var id: String { name }
    }
}

// MARK: - Store

@MainActor @Observable
final class AdmuteStore {
    let client: APIClient
    var live: AdmuteLive?
    var jobs: [AdmuteJob]?
    var recordings: [AdmuteRecordings.Recording]?
    var error: String?
    var notice: String?

    init(client: APIClient) { self.client = client }

    private func load(_ op: () async throws -> Void) async {
        do {
            try await op()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshLive() async { await load { self.live = try await self.client.get("api/live", as: AdmuteLive.self) } }
    func refreshJobs() async { await load { self.jobs = try await self.client.get("api/jobs", as: [AdmuteJob].self) } }
    func refreshRecordings() async {
        await load { self.recordings = try await self.client.get("api/recordings", as: AdmuteRecordings.self).recordings }
    }

    func survey(_ name: String, fresh: Bool) async {
        await load {
            let job: AdmuteJob = try await self.client.fetch("POST", "api/jobs", body: [
                "kind": "survey", "name": .string(name), "fresh": .bool(fresh),
            ])
            self.notice = "\(job.what ?? "Survey") started. Follow it under Jobs."
        }
        await refreshRecordings()
    }

    func stop(_ id: String) async {
        await load { try await self.client.send("POST", "api/jobs/stop", body: ["id": .string(id)]) }
        await refreshJobs()
    }
}

// MARK: - Views

struct AdmuteView: View {
    @State private var store: AdmuteStore

    init(client: APIClient) {
        _store = State(initialValue: AdmuteStore(client: client))
    }

    var body: some View {
        List {
            if let e = store.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if let live = store.live {
                liveSection(live)
                Section {
                    NavigationLink {
                        AdmuteRecordingsView(store: store)
                    } label: {
                        Label("Recordings", systemImage: "film.stack")
                    }
                    NavigationLink {
                        AdmuteJobsView(store: store)
                    } label: {
                        Label("Jobs", systemImage: "gearshape.2")
                    }
                    NavigationLink {
                        ServiceWebPage(client: store.client, title: "Studio", probePath: "api/live")
                    } label: {
                        Label("Open the studio", systemImage: "safari")
                    }
                } footer: {
                    Text("Labelling ads and tuning the detector are in the studio, which is easier on a bigger screen.")
                }
                eventsSection(live.events ?? [])
            } else if store.error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("TV ad mute")
        .refreshable { await store.refreshLive() }
        .polling(every: 3) { await store.refreshLive() }
    }

    @ViewBuilder
    private func liveSection(_ live: AdmuteLive) -> some View {
        Section {
            if let err = live.error {
                Label("Can't reach the admute proxy: \(err)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let sessions = live.status?.sessions, !sessions.isEmpty {
                ForEach(sessions) { sessionRow($0) }
            } else {
                Label("Idle: no channel is open", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Live")
        } footer: {
            if let d = live.status?.delaySeconds {
                Text("Viewers are \(Int(d)) seconds behind live, so ads are muted from their start.")
            }
        }
    }

    private func sessionRow(_ s: AdmuteLive.Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusDot(color: s.mutedNow == true ? .orange : .green)
                Text("\(s.channel) \(s.name ?? "")").font(.headline)
                Spacer()
                if s.mutedNow == true {
                    Label("Muted", systemImage: "speaker.slash.fill").font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Label("Sound on", systemImage: "speaker.wave.2.fill").font(.caption)
                        .foregroundStyle(.green)
                }
            }
            HStack(spacing: 12) {
                Label("\(s.viewers ?? 0)", systemImage: "person.fill")
                if let t = s.openSeconds { Label(Format.duration(t), systemImage: "clock") }
                if let n = s.adsMuted { Label("\(n) ads muted", systemImage: "speaker.slash") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if s.logoLearned == false {
                Text("Learning this channel's logo"
                     + (s.learningMinutesLeft.map { ", about \(Int($0.rounded(.up))) min left" } ?? ""))
                    .font(.caption).foregroundStyle(.blue)
            } else if let score = s.logoScore {
                HStack {
                    Text("Logo match").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: min(max(score, 0), 1))
                        .tint(s.state == "ad" ? Color.orange : Color.green)
                    Text(String(format: "%.2f", score)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if s.detectorRunning == false {
                Text("Detector not running").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func eventsSection(_ events: [String]) -> some View {
        Section("Recent events") {
            if events.isEmpty {
                Text("No ads muted yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(events.prefix(40).enumerated()), id: \.offset) { _, line in
                let e = AdmuteLive.split(line)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.text).font(.callout)
                    if !e.time.isEmpty { Text(e.time).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct AdmuteRecordingsView: View {
    let store: AdmuteStore

    var body: some View {
        List {
            if let e = store.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if let recs = store.recordings {
                if recs.isEmpty {
                    Text("No recordings in the recordings folder.").foregroundStyle(.secondary)
                }
                ForEach(recs) { r in
                    row(r)
                        .swipeActions { actions(r) }
                        .contextMenu { actions(r) }
                }
            } else if store.error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Recordings")
        .refreshable { await store.refreshRecordings() }
        .polling(every: 10) { await store.refreshRecordings() }
        .noticeAlert(Binding(get: { store.notice }, set: { store.notice = $0 }))
    }

    private func row(_ r: AdmuteRecordings.Recording) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(r.title).lineLimit(2)
                Spacer()
                if r.recording == true { Badge(text: "recording", color: .red) }
            }
            HStack(spacing: 6) {
                if let l = r.length { Text(Format.duration(l)) }
                if let size = r.size { Text(Format.bytes(size)) }
                if let m = r.modified { Text(Format.time(m)) }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let job = r.job {
                    Badge(text: (job.what ?? "Job") + (job.progress.map { " · \($0)" } ?? ""), color: .blue)
                } else if r.surveyed == true {
                    Badge(text: "\(r.breaks ?? 0) breaks", color: .green)
                } else {
                    Badge(text: "not surveyed")
                }
                if r.labelled == true { Badge(text: "labelled", color: .purple) }
            }
        }
    }

    @ViewBuilder
    private func actions(_ r: AdmuteRecordings.Recording) -> some View {
        if r.job == nil {
            Button {
                Task { await store.survey(r.name, fresh: false) }
            } label: {
                Label(r.surveyed == true ? "Survey again" : "Survey", systemImage: "waveform.badge.magnifyingglass")
            }
            .tint(.blue)
            if r.surveyed == true {
                Button {
                    Task { await store.survey(r.name, fresh: true) }
                } label: {
                    Label("Survey, learning the logo again", systemImage: "arrow.counterclockwise")
                }
                .tint(.purple)
            }
        }
    }
}

struct AdmuteJobsView: View {
    let store: AdmuteStore

    var body: some View {
        List {
            if let jobs = store.jobs {
                if jobs.isEmpty {
                    Text("No jobs since the studio started.").foregroundStyle(.secondary)
                }
                ForEach(jobs) { j in
                    NavigationLink {
                        AdmuteJobDetailView(store: store, jobId: j.id)
                    } label: {
                        jobRow(j)
                    }
                    .swipeActions {
                        if j.state == "running" {
                            Button("Stop", role: .destructive) { Task { await store.stop(j.id) } }
                        }
                    }
                }
            } else if let e = store.error {
                ErrorBanner(message: e)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Jobs")
        .refreshable { await store.refreshJobs() }
        .polling(every: 3) { await store.refreshJobs() }
    }

    private func jobRow(_ j: AdmuteJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(j.what ?? j.kind)
                Spacer()
                if j.state == "running" { ProgressView().controlSize(.mini) }
                Badge(text: j.state, color: j.color)
            }
            Text(j.title ?? j.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let p = j.progress, j.state == "running" {
                Text("\(p) done").font(.caption2).foregroundStyle(.blue)
            }
        }
    }
}

struct AdmuteJobDetailView: View {
    let store: AdmuteStore
    let jobId: String

    var body: some View {
        Group {
            if let j = store.jobs?.first(where: { $0.id == jobId }) {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(j.what ?? j.kind).font(.headline)
                            Text(j.title ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if j.state == "running" {
                            Button("Stop", role: .destructive) { Task { await store.stop(j.id) } }
                                .buttonStyle(.bordered)
                        } else {
                            Badge(text: j.state, color: j.color)
                        }
                    }
                    .padding()
                    LogView(lines: (j.log ?? "").components(separatedBy: "\n"))
                }
            } else {
                ContentUnavailableView("Job gone", systemImage: "clock",
                                       description: Text("The studio keeps the last 50 jobs until it restarts."))
            }
        }
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
        .polling(every: 2) { await store.refreshJobs() }
    }
}
