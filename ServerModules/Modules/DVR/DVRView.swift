import SwiftUI

// MARK: - Models (dvr-guard: guard.py)

/// GET /api/status
struct DVRStatus: Decodable {
    let recordings: [DVRRecording]
    let channels: [DVRChannel]
    let now: String?
}

/// What each tuned channel is serving.
struct DVRChannel: Decodable, Identifiable {
    let num: String
    let name: String?
    let connected: Bool
    let viewers: Int
    let recordings: [String]
    var id: String { num }
}

/// One entry of dvr-guard's schedule (taken over from Jellyfin).
struct DVRRecording: Decodable, Identifiable {
    let id: String
    /// scheduled, recording, done, missed, failed, cancelled or stopped
    let status: String
    let name: String
    let episode: String?
    let overview: String?
    let channel: String
    let channelName: String?
    let start: String
    let end: String
    /// When it really stops: padding included, or later for a game still on.
    let until: String?
    let bytes: Double?
    /// [[time, seconds missing]]
    let gaps: [[JSONValue]]?
    /// Set when more channels need recording at once than there are tuners.
    let conflict: String?
    let reason: String?
    /// false, or the ESPN game it follows: {league, status, detail}
    let game: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, status, name, episode, overview, channel, start, end, until, bytes, gaps, conflict, reason, game
        case channelName = "channel_name"
    }

    var label: String {
        guard let e = episode, !e.isEmpty else { return name }
        return "\(name) – \(e)"
    }

    var missingSeconds: Int {
        Int((gaps ?? []).compactMap { $0.count > 1 ? $0[1].double : nil }.reduce(0, +))
    }

    var gameDetail: String? {
        guard case .object(let g)? = game else { return nil }
        return g["detail"]?.string ?? g["status"]?.string
    }

    var gameFinal: Bool {
        guard case .object(let g)? = game else { return false }
        return g["status"]?.string == "STATUS_FINAL"
    }

    var isActive: Bool { status == "scheduled" || status == "recording" }

    var statusColor: Color {
        switch status {
        case "recording": return .red
        case "scheduled": return .blue
        case "done": return .green
        case "missed", "failed": return .orange
        default: return .secondary
        }
    }
}

enum DVR {
    /// dvr-guard and Jellyfin write times like 2026-10-31T00:00:00.0000000Z.
    static func date(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: "."),
           let zone = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            s.removeSubrange(dot..<zone)
        }
        if !s.contains("Z") && !s.contains("+") && s.count <= 19 { s += "Z" }
        return parser.date(from: s)
    }

    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// "Today 8:00 PM – 11:15 PM", "Sat, Nov 7 1:00 PM – 4:30 PM".
    static func span(_ r: DVRRecording) -> String {
        guard let start = date(r.start) else { return r.start }
        let end = date(r.until) ?? date(r.end)
        let cal = Calendar.current
        let day = cal.isDateInToday(start) ? "Today"
            : cal.isDateInTomorrow(start) ? "Tomorrow"
            : cal.isDateInYesterday(start) ? "Yesterday"
            : start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end else { return "\(day) \(from)" }
        return "\(day) \(from) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Store

@MainActor @Observable
final class DVRStore {
    let client: APIClient
    var status: DVRStatus?
    var error: String?

    init(client: APIClient) { self.client = client }

    func refresh() async {
        do {
            status = try await client.get("api/status", as: DVRStatus.self)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel(_ r: DVRRecording) async {
        do {
            try await client.send("POST", "api/cancel", body: ["id": .string(r.id)])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }
}

// MARK: - Views

struct DVRView: View {
    @State private var store: DVRStore
    @State private var cancelling: DVRRecording?

    init(client: APIClient) {
        _store = State(initialValue: DVRStore(client: client))
    }

    var body: some View {
        List {
            if let e = store.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if let s = store.status {
                content(s)
            } else if store.error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("DVR")
        .refreshable { await store.refresh() }
        .polling(every: 10) { await store.refresh() }
        .confirmationDialog(cancelling.map { $0.status == "recording" ? "Stop recording \($0.label)?" : "Cancel \($0.label)?" } ?? "",
                            isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                            titleVisibility: .visible, presenting: cancelling) { r in
            Button(r.status == "recording" ? "Stop recording" : "Cancel recording", role: .destructive) {
                Task { await store.cancel(r) }
            }
        } message: { r in
            Text(r.status == "recording"
                 ? "What's recorded so far is kept."
                 : "It's removed from dvr-guard's schedule. To record it again, press Record in Jellyfin.")
        }
    }

    @ViewBuilder
    private func content(_ s: DVRStatus) -> some View {
        let recording = s.recordings.filter { $0.status == "recording" }
        let scheduled = s.recordings.filter { $0.status == "scheduled" }
        let recent = s.recordings.filter { !$0.isActive }.reversed().prefix(30)

        Section("Recording now") {
            if recording.isEmpty {
                Text("Nothing is recording.").foregroundStyle(.secondary)
            }
            ForEach(recording) { r in
                NavigationLink { DVRRecordingView(store: store, id: r.id) } label: { row(r) }
                    .swipeActions { cancelButton(r) }
            }
        }
        Section("Scheduled") {
            if scheduled.isEmpty {
                Text("Nothing scheduled. Press Record on a program in Jellyfin.").foregroundStyle(.secondary)
            }
            ForEach(scheduled) { r in
                NavigationLink { DVRRecordingView(store: store, id: r.id) } label: { row(r) }
                    .swipeActions { cancelButton(r) }
            }
        }
        if !s.channels.isEmpty {
            Section {
                ForEach(s.channels) { c in
                    HStack {
                        StatusDot(color: c.connected ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(c.num) \(c.name ?? "")")
                            Text(channelDetail(c)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Tuners in use")
            } footer: {
                Text("Each channel is pulled from the tuner once, however many viewers and recordings use it.")
            }
        }
        if !recent.isEmpty {
            Section("Recent") {
                ForEach(Array(recent)) { r in
                    NavigationLink { DVRRecordingView(store: store, id: r.id) } label: { row(r) }
                }
            }
        }
    }

    private func channelDetail(_ c: DVRChannel) -> String {
        var parts: [String] = []
        if !c.connected { parts.append("reconnecting") }
        if c.viewers > 0 { parts.append("\(c.viewers) watching") }
        if !c.recordings.isEmpty { parts.append("recording " + c.recordings.joined(separator: ", ")) }
        return parts.isEmpty ? "tuned, idle" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func cancelButton(_ r: DVRRecording) -> some View {
        Button(r.status == "recording" ? "Stop" : "Cancel", role: .destructive) { cancelling = r }
    }

    private func row(_ r: DVRRecording) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.label).lineLimit(2)
            Text("\(DVR.span(r)) · \(r.channel) \(r.channelName ?? "")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            DVRBadges(r: r)
        }
    }
}

/// Status, game, overlap and missing-seconds tags, like the status page.
struct DVRBadges: View {
    let r: DVRRecording

    var body: some View {
        HStack(spacing: 4) {
            if r.status != "scheduled" {
                Badge(text: r.status, color: r.statusColor)
            }
            if let g = r.gameDetail { Badge(text: g, color: r.gameFinal ? .green : .orange) }
            if let c = r.conflict { Badge(text: c, color: .red) }
            if r.missingSeconds > 0 { Badge(text: "\(r.missingSeconds)s missing", color: .orange) }
        }
    }
}

struct DVRRecordingView: View {
    let store: DVRStore
    let id: String
    @State private var confirm = false

    var body: some View {
        Group {
            if let r = store.status?.recordings.first(where: { $0.id == id }) {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.name).font(.headline)
                            if let e = r.episode, !e.isEmpty { Text(e).font(.subheadline) }
                            DVRBadges(r: r)
                        }
                        LabeledContent("Channel", value: "\(r.channel) \(r.channelName ?? "")")
                        LabeledContent("When", value: DVR.span(r))
                        if let b = r.bytes, b > 0 { LabeledContent("Size", value: Format.bytes(b)) }
                        if let reason = r.reason { LabeledContent("Why", value: reason) }
                    }
                    if let o = r.overview, !o.isEmpty {
                        Section("About") { Text(o).font(.callout) }
                    }
                    if r.conflict != nil {
                        Section {
                            Text("More channels need recording at this time than there are tuners. Cancel one, or the later ones wait for a free tuner.")
                                .font(.callout)
                        }
                    }
                    if let gaps = r.gaps, !gaps.isEmpty {
                        Section("Missing") {
                            ForEach(Array(gaps.enumerated()), id: \.offset) { _, g in
                                LabeledContent(DVR.date(g.first?.string)?.formatted(date: .omitted, time: .standard) ?? "–",
                                               value: "\(Int(g.count > 1 ? g[1].double ?? 0 : 0))s")
                            }
                        }
                    }
                    if r.isActive {
                        Section {
                            Button(r.status == "recording" ? "Stop recording" : "Cancel recording", role: .destructive) {
                                confirm = true
                            }
                        }
                    }
                }
                .confirmationDialog(r.status == "recording" ? "Stop recording?" : "Cancel this recording?",
                                    isPresented: $confirm, titleVisibility: .visible) {
                    Button(r.status == "recording" ? "Stop recording" : "Cancel recording", role: .destructive) {
                        Task { await store.cancel(r) }
                    }
                }
            } else {
                ContentUnavailableView("Recording gone", systemImage: "record.circle",
                                       description: Text("It's no longer in dvr-guard's schedule."))
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}
