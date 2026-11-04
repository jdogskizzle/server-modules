import AVKit
import SwiftUI

// MARK: - Models (admute studio: /api/sounds, app/listen.py)

/// GET /api/sounds: sponsor lines per recording, sounds heard more than once, and the answers.
struct AdmuteSoundsPage: Decodable {
    let recordings: [Recording]
    let sounds: [Sound]
    /// When "find reads and repeated sounds" last ran.
    let found: Double?
    /// Answers by key ("read:<recording>@<second>" or "sound:<id>").
    let verdicts: [String: Verdict]

    struct Recording: Decodable, Identifiable {
        let name: String
        let title: String
        /// Transcribed and fingerprinted (the "listen" job ran).
        let listened: Bool?
        let job: AdmuteJob?
        let reads: [Read]
        var id: String { name }
    }

    /// A line of commentary naming a sponsor.
    struct Read: Decodable {
        let start: Double
        let end: Double
        let text: String
        let context: String?
        /// billboard (a sponsor tag or slogan: muted), credit (a feature's sponsor named: left on)
        /// or segment (a brand in a segment's name: left on). Older studios: read or mention.
        let kind: String
        /// The answer's key; it follows the line when it is found again with a different start.
        let key: String?

        /// Whether the rule would mute it.
        var muted: Bool { kind == "billboard" || kind == "read" }

        var kindLabel: String {
            switch kind {
            case "billboard", "read": return "billboard: would mute"
            case "credit", "mention": return "sponsor credit: left on"
            default: return "brand-named segment: left on"
            }
        }
    }

    /// A stretch of sound heard more than once.
    struct Sound: Decodable, Identifiable {
        let id: String
        /// jingle, closer, ad or program
        let guess: String
        let places: [Place]
        let length: Double?
        let recordings: Int?
        let text: String?
        /// The answer's key; it follows the sound when it is found again under another id.
        let key: String?
    }

    struct Place: Decodable, Hashable {
        let name: String
        let start: Double
        let end: Double
        /// Against the breaks: start, end, edge, in, out or across
        let `where`: String?
    }

    struct Verdict: Decodable {
        let value: String
    }

    /// The studio's names for what a sound is.
    static let soundKinds: [(key: String, label: String)] = [
        ("jingle", "Jingle (break edge)"), ("closer", "Network promo (ends breaks)"), ("ad", "Ad"),
        ("program", "Part of the game"), ("ignore", "Not useful"),
    ]

    static func soundLabel(_ key: String) -> String {
        soundKinds.first { $0.key == key }?.label ?? key
    }
}

// MARK: - Playing a moment of a recording

enum AdmuteVideo {
    /// The recording as the studio's HLS stream, opened with the app's session.
    static func player(client: APIClient, recording name: String) async throws -> AVPlayer {
        let cookies = try await client.webCookies()
        var options: [String: Any] = [AVURLAssetHTTPCookiesKey: cookies]
        if let header = client.headerName, let value = client.headerValue, !header.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = [header: value]
        }
        let url = client.url("api/rec/\(APIClient.segment(name))/hls.m3u8", query: [URLQueryItem(name: "h", value: "540")])
        // Play sound even with the ring/silent switch on: judging sounds needs it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: options)))
    }
}

/// One player for the whole Sounds screen; ▶ on any row plays that moment.
@MainActor @Observable
final class AdmuteClipPlayer {
    let client: APIClient
    var player: AVPlayer?
    var recording: String?
    var caption = ""
    var error: String?

    init(client: APIClient) { self.client = client }

    func play(_ name: String, at t: Double, caption: String) async {
        self.caption = caption
        do {
            if recording != name || player == nil {
                player?.pause()
                player = try await AdmuteVideo.player(client: client, recording: name)
                recording = name
            }
            _ = await player?.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600),
                               toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
            player?.play()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        player?.pause()
    }
}

// MARK: - Store

@MainActor @Observable
final class AdmuteSoundsStore {
    let client: APIClient
    var page: AdmuteSoundsPage?
    var verdicts: [String: String] = [:]
    var error: String?
    var notice: String?
    /// The studio predates Sounds (no /api/sounds).
    var unsupported = false

    init(client: APIClient) { self.client = client }

    func refresh() async {
        do {
            let p = try await client.get("api/sounds", as: AdmuteSoundsPage.self)
            page = p
            verdicts = p.verdicts.mapValues(\.value)
            error = nil
        } catch is CancellationError {
        } catch let e as APIError where e.message.contains("404") || e.message == "not found" {
            unsupported = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    var busy: Bool { page?.recordings.contains { $0.job != nil } ?? false }

    static func readKey(_ rec: AdmuteSoundsPage.Recording, _ read: AdmuteSoundsPage.Read) -> String {
        read.key ?? "read:\(rec.name)@\(Int(read.start.rounded()))"
    }

    /// Sets an answer; picking the current one again clears it, like the studio.
    func setVerdict(_ key: String, _ value: String) async {
        let new = verdicts[key] == value ? "" : value
        verdicts[key] = new.isEmpty ? nil : new
        do {
            let saved: [String: AdmuteSoundsPage.Verdict] = try await client.fetch(
                "POST", "api/sounds/verdict", body: ["key": .string(key), "value": .string(new)])
            verdicts = saved.mapValues(\.value)
            error = nil
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            await refresh()
        }
    }

    func startJob(kind: String, name: String, started: String) async {
        do {
            let _: AdmuteJob = try await client.fetch("POST", "api/jobs", body: ["kind": .string(kind), "name": .string(name)])
            notice = started
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }
}

// MARK: - View

struct AdmuteSoundsView: View {
    @State private var store: AdmuteSoundsStore
    @State private var clips: AdmuteClipPlayer
    @AppStorage("admute.sounds.allReads") private var allReads = false
    @State private var openSounds: Set<String> = []

    init(client: APIClient) {
        _store = State(initialValue: AdmuteSoundsStore(client: client))
        _clips = State(initialValue: AdmuteClipPlayer(client: client))
    }

    var body: some View {
        List {
            if let e = store.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if store.unsupported {
                ContentUnavailableView("Sounds isn't available", systemImage: "waveform",
                                       description: Text("This admute studio is older than the Sounds feature. Update admute to use it."))
            } else if let page = store.page {
                playerSection
                listeningSection(page)
                readsSection(page)
                soundsSection(page)
            } else if store.error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Sounds")
        .refreshable { await store.refresh() }
        .polling(every: 5) { await store.refresh() }
        .onDisappear { clips.stop() }
        .noticeAlert(Binding(get: { store.notice }, set: { store.notice = $0 }))
    }

    // MARK: Player

    private var playerSection: some View {
        Section {
            if let player = clips.player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
                if !clips.caption.isEmpty {
                    Text(clips.caption).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            } else {
                Label("Press ▶ on a row to hear it", systemImage: "play.circle")
                    .foregroundStyle(.secondary)
            }
            if let e = clips.error {
                Text("Can't play: \(e)").font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text("Sponsor billboards would be muted while the picture plays on; jingles and network promos mark where breaks start and end. Confirm what each one is.")
        }
    }

    private func play(_ name: String, _ t: Double, _ caption: String) {
        Task { await clips.play(name, at: t, caption: caption) }
    }

    // MARK: Listening

    private func listeningSection(_ page: AdmuteSoundsPage) -> some View {
        let listened = page.recordings.filter { $0.listened == true }
        return Section {
            ForEach(page.recordings) { r in
                HStack {
                    Text(r.title).lineLimit(2)
                    Spacer()
                    if let job = r.job {
                        Badge(text: job.progress ?? job.what ?? "working", color: .orange)
                    } else {
                        if r.listened == true { Badge(text: "listened", color: .green) }
                        Button(r.listened == true ? "Again" : "Listen") {
                            Task { await store.startJob(kind: "listen", name: r.name, started: "Listening to \(r.title). It takes about 4 minutes per game.") }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Button {
                Task { await store.startJob(kind: "sounds", name: "", started: "Finding sponsor lines and repeated sounds. Follow it under Jobs.") }
            } label: {
                Label("Find reads and repeated sounds", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(listened.isEmpty || store.busy)
        } header: {
            Text("Listening")
        } footer: {
            Text((page.found.map { "Last found \(Format.ago($0)). " } ?? "Not run yet. ")
                 + "Listening transcribes the commentary and fingerprints the sound, about 4 minutes per game on the GPU.")
        }
    }

    // MARK: Sponsor lines

    @ViewBuilder
    private func readsSection(_ page: AdmuteSoundsPage) -> some View {
        let rows = page.recordings.flatMap { rec in
            rec.reads.compactMap { read -> (id: String, rec: AdmuteSoundsPage.Recording, read: AdmuteSoundsPage.Read, key: String)? in
                if !allReads && !read.muted { return nil }
                return ("\(rec.name)@\(read.start)", rec, read, AdmuteSoundsStore.readKey(rec, read))
            }
        }
        let total = page.recordings.reduce(0) { $0 + $1.reads.count }
        Section {
            Toggle("Also sponsor credits and brand-named segments", isOn: $allReads)
            if rows.isEmpty {
                Text(total > 0 ? "None to show." : "Listen to a recording, then find sponsor lines.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.id) { row in
                readRow(row.rec, row.read, key: row.key)
            }
        } header: {
            Text("Sponsor lines")
        } footer: {
            Text("Billboards (the broadcast's sponsor tags and slogans) would be muted; a feature's sponsor credit or a brand-named segment is left on. Mute or Keep says what you'd want. Tap again to clear.")
        }
    }

    private func readRow(_ rec: AdmuteSoundsPage.Recording, _ read: AdmuteSoundsPage.Read, key: String) -> some View {
        let v = store.verdicts[key]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(AdmuteTime.hms(read.start)).font(.caption.monospacedDigit())
                Badge(text: read.kindLabel, color: read.muted ? .orange : .secondary)
                if let v, (v == "mute") != read.muted {
                    Badge(text: "you said \(v)", color: .red)
                }
                Text(rec.title.replacingOccurrences(of: "NFL Football ", with: ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("“\(read.text)”").font(.callout)
            + Text("  \(String(format: "%.1f", read.end - read.start))s").font(.caption).foregroundColor(.secondary)
            HStack {
                Button {
                    play(rec.name, read.start - 4, read.text)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
                verdictButton("Mute", key: key, value: "mute", current: v, tint: .red)
                verdictButton("Keep", key: key, value: "keep", current: v, tint: .green)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func verdictButton(_ title: String, key: String, value: String, current: String?, tint: Color) -> some View {
        Group {
            if current == value {
                Button(title) { Task { await store.setVerdict(key, value) } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title) { Task { await store.setVerdict(key, value) } }
                    .buttonStyle(.bordered)
            }
        }
        .tint(tint)
    }

    // MARK: Repeated sounds

    @ViewBuilder
    private func soundsSection(_ page: AdmuteSoundsPage) -> some View {
        Section {
            if page.sounds.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(page.sounds) { s in soundRow(s) }
        } header: {
            Text("Repeated sounds")
        } footer: {
            Text("Sounds heard more than once, most often first, with a guess from where they fall against the ads.")
        }
    }

    private func soundRow(_ s: AdmuteSoundsPage.Sound) -> some View {
        let key = s.key ?? "sound:\(s.id)"
        let v = store.verdicts[key]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Badge(text: AdmuteSoundsPage.soundLabel(s.guess) + "?", color: .blue)
                Text("\(s.places.count)× in \(s.recordings ?? 1) rec" + (s.length.map { " · \(Format.number($0, digits: 1))s" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(AdmuteSoundsPage.soundKinds, id: \.key) { kind in
                        Button {
                            Task { await store.setVerdict(key, kind.key) }
                        } label: {
                            if v == kind.key { Label(kind.label, systemImage: "checkmark") } else { Text(kind.label) }
                        }
                    }
                } label: {
                    Text(v.map(AdmuteSoundsPage.soundLabel) ?? "What is it?")
                        .font(.caption.weight(.semibold))
                }
            }
            if let text = s.text, !text.isEmpty {
                Text("“\(String(text.prefix(160)))”").font(.callout)
            } else {
                Text("No words (music?)").font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: Binding(
                get: { openSounds.contains(s.id) },
                set: { if $0 { openSounds.insert(s.id) } else { openSounds.remove(s.id) } })) {
                ForEach(s.places, id: \.self) { p in
                    Button {
                        play(p.name, p.start - 3,
                             "\(AdmuteSoundsPage.soundLabel(s.guess)): \(AdmuteTime.hms(p.start))–\(AdmuteTime.hms(p.end)) (\(p.where ?? ""))")
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text(AdmuteTime.hms(p.start)).monospacedDigit()
                            Text(p.where ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Text(recordingTitle(p.name)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } label: {
                Text("Where it was heard").font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func recordingTitle(_ name: String) -> String {
        (store.page?.recordings.first { $0.name == name }?.title ?? name)
            .replacingOccurrences(of: "NFL Football ", with: "")
    }
}
