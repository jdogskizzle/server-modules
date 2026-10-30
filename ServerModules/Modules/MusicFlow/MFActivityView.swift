import SwiftUI

struct MFActivityView: View {
    let store: MusicFlowStore

    var body: some View {
        List {
            if let e = store.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if let jobs = store.jobs {
                if let w = jobs.worker, !w.running, let note = w.note, !note.isEmpty {
                    Section { Label("Paused: \(note)", systemImage: "pause.circle").foregroundStyle(.orange) }
                }
                let active = jobs.jobs.filter(\.isActive)
                let done = jobs.jobs.filter { !$0.isActive }
                if jobs.jobs.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "music.note",
                                           description: Text("Pick an artist and search their missing albums."))
                }
                if !active.isEmpty {
                    Section("In progress") { ForEach(active) { row($0) } }
                }
                if !done.isEmpty {
                    Section("Finished") { ForEach(done) { row($0) } }
                }
            } else if store.error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await store.clearFinished() }
                    } label: {
                        Label("Clear finished", systemImage: "trash")
                    }
                    if store.overview?.jellyfin == true {
                        Button {
                            Task { await store.scanJellyfin() }
                        } label: {
                            Label("Scan Jellyfin music", systemImage: "play.tv")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await store.refreshJobs() }
        .polling(every: 3) { await store.refreshJobs() }
        .noticeAlert(Binding(get: { store.notice }, set: { store.notice = $0 }))
    }

    private func row(_ j: MFJob) -> some View {
        NavigationLink {
            MFJobDetailView(store: store, jobId: j.id)
        } label: {
            MFJobRow(job: j)
        }
        .swipeActions(edge: .trailing) { actions(j) }
        .contextMenu { actions(j) }
    }

    @ViewBuilder
    private func actions(_ j: MFJob) -> some View {
        if j.canRetry {
            Button("Retry") { Task { await store.jobAction(j.id, "retry") } }.tint(.blue)
        }
        if j.canCancel {
            Button("Cancel", role: .destructive) { Task { await store.jobAction(j.id, "cancel") } }
        }
        if j.canDismiss {
            Button("Dismiss") { Task { await store.jobAction(j.id, "dismiss") } }.tint(.gray)
        }
    }
}

struct MFJobRow: View {
    let job: MFJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(job.artist ?? "") — \(job.album ?? "")").lineLimit(2)
                Spacer()
                Badge(text: job.kindLabel)
            }
            HStack(spacing: 6) {
                if job.status == "processing" { ProgressView().controlSize(.mini) }
                Text(job.statusText).foregroundStyle(MF.statusColor(job.status))
                if job.kind == "download", let n = job.fileCount {
                    Text("· \(n) files · \(Format.bytes(job.size))\(job.username.map { " from \($0)" } ?? "")")
                        .foregroundStyle(.secondary)
                }
                if !MF.speed(job.speed).isEmpty, job.status == "queued" {
                    Text("· " + MF.speed(job.speed)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            if job.kind == "download", job.status == "queued" {
                ProgressView(value: min(job.pct ?? 0, 100), total: 100)
            }
            if let e = job.error, !e.isEmpty {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Text(Format.ago(job.finishedAt ?? job.created)).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct MFJobDetailView: View {
    let store: MusicFlowStore
    let jobId: String

    var body: some View {
        Group {
            if let j = store.jobs?.jobs.first(where: { $0.id == jobId }) {
                List {
                    Section { MFJobRow(job: j) }
                    if j.canRetry || j.canCancel || j.canDismiss {
                        Section {
                            if j.canRetry { Button("Retry") { Task { await store.jobAction(j.id, "retry") } } }
                            if j.canCancel {
                                Button("Cancel", role: .destructive) { Task { await store.jobAction(j.id, "cancel") } }
                            }
                            if j.canDismiss { Button("Dismiss") { Task { await store.jobAction(j.id, "dismiss") } } }
                        }
                    }
                    ForEach(Array((j.reports ?? []).enumerated()), id: \.offset) { _, r in
                        Section(r["album"]?.string ?? "Report") { report(r) }
                    }
                    if let log = j.log, !log.isEmpty {
                        Section("Log") {
                            Text(log.joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Job gone", systemImage: "checkmark.circle",
                                       description: Text("It was dismissed or cleared."))
            }
        }
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
        .polling(every: 3) { await store.refreshJobs() }
    }

    @ViewBuilder
    private func report(_ r: [String: JSONValue]) -> some View {
        if let e = r["error"]?.string {
            Text(e).foregroundStyle(.red)
        } else {
            let date = [r["date"]?.string, r["date_src"]?.string.map { "from \($0)" }].compactMap { $0 }.joined(separator: " ")
            LabeledContent("Date", value: date.isEmpty ? "–" : date)
            if let note = r["year_note"]?.string { Text(note).font(.caption).foregroundStyle(.orange) }
            if let url = r["wiki_url"]?.string, let u = URL(string: url) {
                Link("Wikipedia page", destination: u)
            }
            LabeledContent("Cover", value: r["cover"]?.string ?? "–")
            LabeledContent("Tags", value: (r["tagged"]?.string).map { "\($0) files" } ?? "–")
            LabeledContent("Lyrics", value: r["lyrics"]?.string ?? "–")
            if let perms = r["perms"]?.string { LabeledContent("Permissions", value: perms) }
            if let dir = r["host_dir"]?.string ?? r["dir"]?.string {
                Text(dir).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Import

struct MFImportView: View {
    let store: MusicFlowStore
    @State private var folders: [MFFolders.Folder]?
    @State private var error: String?
    @State private var chosen: MFFolders.Folder?

    var body: some View {
        List {
            if let error {
                Section { ErrorBanner(message: error) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if let folders {
                Section {
                    if folders.isEmpty {
                        Text("No folders with audio files in the downloads folder.").foregroundStyle(.secondary)
                    }
                    ForEach(folders) { f in
                        Button {
                            chosen = f
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).foregroundStyle(.primary)
                                Text("\(f.files) audio files · \(Format.ago(f.mtime))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Folders in the slskd download folder, such as things you grabbed by hand. Importing one runs the usual finish steps: cover, tags and lyrics.")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Import")
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $chosen) { f in
            NavigationStack { MFImportSheet(store: store, folder: f) }
        }
    }

    private func load() async {
        do {
            folders = try await store.client.get("api/folders", as: MFFolders.self).folders
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MFImportSheet: View {
    let store: MusicFlowStore
    let folder: MFFolders.Folder
    @Environment(\.dismiss) private var dismiss
    @State private var artist: MFArtistSummary?
    @State private var guess: MFImportGuess?
    @State private var albumId: Int?
    @State private var forceCover = false
    @State private var allowLossy = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section("Folder") {
                Text(folder.name)
                Text("\(guess?.files ?? folder.files) audio files").font(.caption).foregroundStyle(.secondary)
            }
            Section("Artist") {
                NavigationLink {
                    MFArtistPicker(artists: store.overview?.artists ?? [], selection: $artist)
                } label: {
                    LabeledContent("Artist", value: artist?.name ?? "Choose")
                }
            }
            if let g = guess {
                Section("Album") {
                    Picker("Album", selection: $albumId) {
                        Text("Choose").tag(Int?.none)
                        ForEach(g.albums) { a in
                            Text(a.year.map { "\(a.title) (\($0))" } ?? a.title).tag(Int?.some(a.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section {
                    Toggle("Get a new cover", isOn: $forceCover)
                    Toggle("Allow lossy files", isOn: $allowLossy)
                }
            } else if artist != nil, working {
                Section { HStack { ProgressView(); Text("Matching the album…") } }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Import folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") { Task { await submit() } }
                    .disabled(artist == nil || albumId == nil || working)
            }
        }
        .task(id: artist?.id) { await loadGuess() }
        .task { if store.overview == nil { await store.refreshOverview() } }
    }

    private func loadGuess() async {
        guard let artist else { return }
        working = true
        defer { working = false }
        guess = nil
        albumId = nil
        do {
            let g: MFImportGuess = try await store.client.fetch("POST", "api/import/guess", body: [
                "folder": .string(folder.path), "artist_id": .number(Double(artist.id)),
            ])
            guess = g
            albumId = g.guess
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit() async {
        guard let artist, let albumId else { return }
        working = true
        defer { working = false }
        do {
            try await store.client.send("POST", "api/import", body: [
                "folder": .string(folder.path), "artist_id": .number(Double(artist.id)),
                "album_id": .number(Double(albumId)), "force_cover": .bool(forceCover), "allow_lossy": .bool(allowLossy),
            ])
            store.notice = "Import queued. Follow it under Activity."
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MFArtistPicker: View {
    let artists: [MFArtistSummary]
    @Binding var selection: MFArtistSummary?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        List(artists.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }) { a in
            Button {
                selection = a
                dismiss()
            } label: {
                HStack {
                    Text(a.name).foregroundStyle(.primary)
                    Spacer()
                    if selection?.id == a.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Artist")
    }
}
