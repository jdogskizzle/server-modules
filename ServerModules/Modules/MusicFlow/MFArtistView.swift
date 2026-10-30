import SwiftUI

@MainActor @Observable
final class MFArtistStore {
    let client: APIClient
    let artistId: Int
    var artist: MFArtist?
    var error: String?
    var notice: String?
    var working = false
    /// The source picked for each missing album (album id → candidate).
    var picks: [Int: MFCandidate] = [:]
    /// Albums the user un-picked, so the best result isn't picked again for them.
    var skipped: Set<Int> = []

    init(client: APIClient, artistId: Int) {
        self.client = client
        self.artistId = artistId
    }

    func refresh() async {
        do {
            artist = try await client.get("api/artist/\(artistId)")
            error = nil
            autoPick()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    var missing: [MFAlbum] { (artist?.albums ?? []).filter { $0.status == "missing" && $0.monitored } }

    func album(_ id: Int) -> MFAlbum? { artist?.albums.first { $0.id == id } }

    /// Preselect the best result for each searched album, like the web app does.
    private func autoPick() {
        for a in missing {
            let cands = a.search?.candidates ?? []
            if let p = picks[a.id], !cands.contains(where: { $0.id == p.id }) { picks[a.id] = nil }
            guard picks[a.id] == nil, !skipped.contains(a.id), a.search?.state == "done" else { continue }
            let usable = cands.filter { !($0.failed ?? false) }
            picks[a.id] = usable.first { $0.formatOk != false } ?? usable.first
        }
        for id in picks.keys where !missing.contains(where: { $0.id == id }) { picks[id] = nil }
    }

    func pick(_ c: MFCandidate?, for albumId: Int) {
        picks[albumId] = c
        if c == nil { skipped.insert(albumId) } else { skipped.remove(albumId) }
    }

    private func run(_ success: String? = nil, _ op: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await op()
            error = nil
            if let success { notice = success }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func search(_ albumIds: [Int], text: String? = nil) async {
        let ids = albumIds.map { JSONValue.number(Double($0)) }
        await run {
            try await self.client.send("POST", "api/search", body: ["album_ids": .array(ids), "text": JSONValue(text)])
        }
    }

    func downloadPicked() async {
        let chosen = picks.filter { id, _ in missing.contains { $0.id == id && $0.job?.isActive != true } }
        guard !chosen.isEmpty else { return }
        let body: [JSONValue] = chosen.map { id, c in
            ["album_id": .number(Double(id)), "username": .string(c.username), "dir": .string(c.dir)]
        }
        await run("Added \(chosen.count) download\(chosen.count == 1 ? "" : "s"). Follow them under Activity.") {
            try await self.client.send("POST", "api/pick", body: ["picks": .array(body)])
            for id in chosen.keys { self.picks[id] = nil }
        }
    }

    func finish(_ albumIds: [Int], forceCover: Bool) async {
        let ids = albumIds.map { JSONValue.number(Double($0)) }
        await run("Re-tagging queued. Follow it under Activity.") {
            try await self.client.send("POST", "api/finish", body: [
                "artist_id": .number(Double(self.artistId)), "album_ids": .array(ids), "force_cover": .bool(forceCover),
            ])
        }
    }
}

struct MFArtistView: View {
    let store: MusicFlowStore
    let name: String
    @State private var model: MFArtistStore

    init(store: MusicFlowStore, artistId: Int, name: String) {
        self.store = store
        self.name = name
        _model = State(initialValue: MFArtistStore(client: store.client, artistId: artistId))
    }

    var body: some View {
        List {
            if let e = model.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if let artist = model.artist {
                sections(artist)
            } else if model.error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle(name)
        .navigationDestination(for: AlbumRoute.self) { r in
            MFAlbumSearchView(model: model, albumId: r.id)
        }
        .safeAreaInset(edge: .bottom) { downloadBar }
        .refreshable { await model.refresh() }
        .polling(every: 5) { await model.refresh() }
        .noticeAlert($model.notice)
    }

    struct AlbumRoute: Hashable { let id: Int }

    @ViewBuilder
    private func sections(_ artist: MFArtist) -> some View {
        let missing = model.missing
        let active = artist.albums.filter { $0.status == "active" }
        let have = artist.albums.filter { $0.status == "have" }
        let other = artist.albums.filter { !["missing", "active", "have"].contains($0.status) || ($0.status == "missing" && !$0.monitored) }

        Section {
            if missing.isEmpty {
                Text("Nothing missing.").foregroundStyle(.secondary)
            } else {
                let unsearched = missing.filter { $0.search == nil || $0.search?.state == "error" }
                Button {
                    Task { await model.search(unsearched.isEmpty ? missing.map(\.id) : unsearched.map(\.id)) }
                } label: {
                    Label(unsearched.isEmpty ? "Search all \(missing.count) again" : "Search \(unsearched.count) missing album\(unsearched.count == 1 ? "" : "s")",
                          systemImage: "magnifyingglass")
                }
                .disabled(model.working || store.overview?.slskd == false)
                ForEach(missing) { a in
                    NavigationLink(value: AlbumRoute(id: a.id)) { missingRow(a) }
                }
            }
        } header: {
            Text("Missing")
        } footer: {
            if !missing.isEmpty {
                Text("Tap an album to see its search results and choose a source. The best result is picked for you.")
            }
        }

        if !active.isEmpty {
            Section("In progress") {
                ForEach(active) { a in activeRow(a) }
            }
        }

        if !have.isEmpty {
            Section {
                ForEach(have) { a in
                    albumHeader(a, detail: [a.year, a.date.map { "date \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .contextMenu { retagButtons(a) }
                        .swipeActions { retagButtons(a) }
                }
            } header: {
                Text("In library")
            } footer: {
                Text("Long-press or swipe an album to re-tag it.")
            }
        }

        if !other.isEmpty {
            Section("Other") {
                ForEach(other) { a in
                    albumHeader(a, detail: [a.year, MF.statusLabel(a.status) + (a.status == "partial" ? " \(a.have)/\(a.total)" : ""),
                                            a.monitored ? nil : "not monitored"].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
    }

    @ViewBuilder
    private func retagButtons(_ a: MFAlbum) -> some View {
        Button {
            Task { await model.finish([a.id], forceCover: false) }
        } label: {
            Label("Re-tag", systemImage: "tag")
        }
        .tint(.blue)
        Button {
            Task { await model.finish([a.id], forceCover: true) }
        } label: {
            Label("Re-tag + new cover", systemImage: "photo")
        }
        .tint(.purple)
    }

    private func albumHeader(_ a: MFAlbum, detail: String) -> some View {
        HStack(spacing: 12) {
            ServerImage(client: model.client, path: "api/art/album/\(a.id)")
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func missingRow(_ a: MFAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            albumHeader(a, detail: [a.year, a.kindLabel, a.want].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            searchSummary(a)
        }
    }

    @ViewBuilder
    private func searchSummary(_ a: MFAlbum) -> some View {
        if let j = a.job, j.isActive {
            Label(j.statusText, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.blue)
        } else if let s = a.search {
            if s.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(s.state == "queued" ? "Waiting to search…" : "Searching…")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if s.state == "error" {
                Text(s.error ?? "Search failed").font(.caption).foregroundStyle(.red)
            } else if let p = model.picks[a.id] {
                Label("\(p.folder) · \(p.quality.isEmpty ? p.ext : p.quality) · \(p.username)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(p.formatOk == false ? Color.orange : Color.green)
                    .lineLimit(1)
            } else if (s.candidates ?? []).isEmpty {
                Text("No results").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(s.total ?? s.candidates?.count ?? 0) results, none picked").font(.caption).foregroundStyle(.secondary)
            }
        } else if let j = a.job, j.status == "failed" {
            Text(j.error ?? "Failed").font(.caption).foregroundStyle(.red)
        } else {
            Text("Not searched yet").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func activeRow(_ a: MFAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            albumHeader(a, detail: [a.year, a.job?.kindLabel].compactMap { $0 }.joined(separator: " · "))
            if let j = a.job {
                Text(j.statusText).font(.caption).foregroundStyle(.blue)
                if j.kind == "download", j.status == "queued" {
                    ProgressView(value: min(j.pct ?? 0, 100), total: 100)
                }
            }
        }
    }

    @ViewBuilder
    private var downloadBar: some View {
        let count = model.picks.keys.filter { id in model.missing.contains { $0.id == id && $0.job?.isActive != true } }.count
        if count > 0 {
            Button {
                Task { await model.downloadPicked() }
            } label: {
                HStack {
                    if model.working { ProgressView().tint(.white) }
                    Text("Download and finish \(count) album\(count == 1 ? "" : "s")")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.working)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }
}

/// One missing album's search results; pick the source to download from.
struct MFAlbumSearchView: View {
    let model: MFArtistStore
    let albumId: Int
    @State private var text = ""
    @State private var editedText = false

    var body: some View {
        List {
            if let a = model.album(albumId) {
                Section {
                    HStack(spacing: 12) {
                        ServerImage(client: model.client, path: "api/art/album/\(a.id)")
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(.headline)
                            Text([a.year, a.kindLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if let w = a.search?.release ?? a.want {
                                Text("Wants: \(w)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    TextField("Search text", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { search() }
                        .onChange(of: text) { editedText = true }
                    Button {
                        search()
                    } label: {
                        Label(a.search == nil ? "Search" : "Search again", systemImage: "magnifyingglass")
                    }
                    .disabled(model.working || a.search?.running == true)
                } footer: {
                    Text("Leave the text as it is, or try other words (e.g. without the year).")
                }
                results(a)
            }
        }
        .navigationTitle("Choose a source")
        .navigationBarTitleDisplayMode(.inline)
        .polling(every: 4) { await model.refresh() }
        .onAppear {
            if !editedText, let t = model.album(albumId)?.search?.text { text = t }
        }
    }

    private func search() {
        let t = text.trimmingCharacters(in: .whitespaces)
        Task { await model.search([albumId], text: t.isEmpty ? nil : t) }
    }

    @ViewBuilder
    private func results(_ a: MFAlbum) -> some View {
        if let s = a.search {
            if s.running {
                Section { HStack { ProgressView(); Text("Searching Soulseek…").foregroundStyle(.secondary) } }
            } else if s.state == "error" {
                Section { Text(s.error ?? "Search failed").foregroundStyle(.red) }
            } else {
                let cands = s.candidates ?? []
                Section {
                    Button {
                        model.pick(nil, for: a.id)
                    } label: {
                        HStack {
                            Image(systemName: model.picks[a.id] == nil ? "checkmark.circle.fill" : "circle")
                            Text("Don't download this album")
                        }
                    }
                    ForEach(cands) { c in candidateRow(c, albumId: a.id) }
                } header: {
                    Text(cands.isEmpty ? "No results" : "\(s.total ?? cands.count) results")
                } footer: {
                    if let total = s.total, total > cands.count { Text("Showing the best \(cands.count).") }
                }
            }
        }
    }

    private func candidateRow(_ c: MFCandidate, albumId: Int) -> some View {
        let picked = model.picks[albumId]?.id == c.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.pick(c, for: albumId)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.folder).foregroundStyle(.primary).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(c.quality.isEmpty ? c.ext.uppercased() : "\(c.ext.uppercased()) \(c.quality)")
                                .foregroundStyle(c.formatOk == false ? Color.orange : Color.primary)
                            Text("\(c.count) files")
                            if let size = c.size, size > 0 { Text(Format.bytes(size)) }
                        }
                        .font(.caption)
                        HStack(spacing: 6) {
                            Text(c.username)
                            Text(c.free == true ? "free slot" : "queue \(Int(c.queue ?? 0))")
                            if !MF.speed(c.speed).isEmpty { Text(MF.speed(c.speed)) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Badge(text: "score \(c.score)")
                            if c.multidisc == true { Badge(text: "discs", color: .blue) }
                            if c.formatOk == false { Badge(text: "other format", color: .orange) }
                            if c.failed == true { Badge(text: "failed before", color: .red) }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            DisclosureGroup("Files") {
                ForEach(Array(c.files.enumerated()), id: \.offset) { _, f in
                    Text(f).font(.caption.monospaced()).lineLimit(1)
                }
            }
            .font(.caption)
        }
    }
}
