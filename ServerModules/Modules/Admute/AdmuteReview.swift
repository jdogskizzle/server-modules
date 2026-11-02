import SwiftUI

// MARK: - Models

/// GET /api/rec/<name>: one recording's survey and labels (the timeline is ignored).
struct AdmuteRecordingDetail: Decodable {
    let name: String
    let title: String
    let result: Survey?
    let labels: AdmuteLabels

    struct Survey: Decodable {
        let length: Double
        /// What the detector muted: [[start, end]] in seconds.
        let breaks: [[Double]]
    }
}

/// The recording's labels: where the ads really are, plus the review's answers.
/// Sent back whole to POST /api/rec/<name>/labels.
struct AdmuteLabels: Codable {
    /// [[start, end]] or [[start, end, "sbs"]] for a side-by-side ad.
    var ads: [[JSONValue]] = []
    var reviewed: Bool? = false
    var notes: String? = ""
    /// The review's answer per mute, keyed by the mute's start second.
    var review: [String: Answer]? = [:]
    var missedChecked: Bool? = false

    struct Answer: Codable {
        /// right, wrong or partly
        var verdict: String
        /// The corrected [start, end] of a "partly" answer.
        var span: [Double]?
    }

    enum CodingKeys: String, CodingKey {
        case ads, reviewed, notes, review
        case missedChecked = "missed_checked"
    }
}

struct AdmuteAd {
    var s: Double
    var e: Double
    var sbs: Bool
    /// The label exactly as stored, so existing labels go back unchanged.
    private var raw: [JSONValue]?

    init(_ v: [JSONValue]) {
        s = v.first?.double ?? 0
        e = v.count > 1 ? v[1].double ?? 0 : 0
        sbs = v.count > 2 && v[2].string == "sbs"
        raw = v
    }

    init(s: Double, e: Double, sbs: Bool) {
        self.s = s.rounded()
        self.e = e.rounded()
        self.sbs = sbs
    }

    var json: [JSONValue] { raw ?? ([.number(s), .number(e)] + (sbs ? [.string("sbs")] : [])) }

    func overlaps(_ a: Double, _ b: Double) -> Bool { e > a && s < b }

    mutating func toggleSbs() {
        sbs.toggle()
        raw = nil
    }
}

enum AdmuteTime {
    /// 1:23:45 or 12:34
    static func hms(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Review state (same rules as the studio's review mode)

@MainActor @Observable
final class AdmuteReview {
    struct Mute: Identifiable {
        let s: Double
        let e: Double
        let key: String
        var id: String { key }
    }

    enum Step: String { case mutes, missed }

    let client: APIClient
    let name: String
    var title = ""
    var length: Double = 0
    var mutes: [Mute] = []
    var labels = AdmuteLabels()
    var loaded = false
    var surveyed = true
    var error: String?
    /// The mute being checked (== mutes.count once all are answered).
    var index = 0
    var step = Step.mutes
    /// [start, end] being fixed (a "partly" answer) or marked (a missed ad).
    var edit: [Double]?
    /// Where the edit's two picture strips are centred.
    var anchors: [Double] = [0, 0]
    /// Missed ads: the picture tapped.
    var pick: Double?
    private var saveTask: Task<Void, Never>?

    init(client: APIClient, name: String) {
        self.client = client
        self.name = name
    }

    var path: String { "api/rec/\(APIClient.segment(name))" }

    func load() async {
        do {
            let d = try await client.get(path, as: AdmuteRecordingDetail.self)
            title = d.title
            guard let survey = d.result else {
                surveyed = false
                loaded = true
                return
            }
            length = survey.length
            mutes = survey.breaks.compactMap { b in
                b.count >= 2 ? Mute(s: b[0], e: b[1], key: String(Int(b[0].rounded(.down)))) : nil
            }
            var l = d.labels
            var review = l.review ?? [:]
            // Answers saved under a slightly different start (a newer survey) still count.
            for m in mutes where review[m.key] == nil {
                if let near = review.keys.first(where: { abs((Double($0) ?? -1e9) - m.s) <= 3 }) {
                    review[m.key] = review[near]
                    review[near] = nil
                }
            }
            l.review = review
            labels = l
            index = mutes.firstIndex { review[$0.key] == nil } ?? max(mutes.count - 1, 0)
            loaded = true
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    var ads: [AdmuteAd] { labels.ads.map(AdmuteAd.init) }
    func answer(of m: Mute) -> AdmuteLabels.Answer? { labels.review?[m.key] }
    var checkedCount: Int { mutes.filter { answer(of: $0) != nil }.count }
    var wrongCount: Int { mutes.filter { answer(of: $0)?.verdict == "wrong" }.count }

    // ----- step 1: the mutes -----

    /// Right / wrong / partly (with the corrected span). The answers become the labels.
    func answer(_ verdict: String, span: [Double]? = nil) {
        guard mutes.indices.contains(index) else { return }
        let m = mutes[index]
        let current = ads
        let keepSbs = current.contains { $0.sbs && $0.overlaps(m.s, m.e) }
        var kept = current.filter { ad in
            !ad.overlaps(m.s, m.e) && !(span.map { ad.overlaps($0[0], $0[1]) } ?? false)
        }
        if verdict == "right" { kept.append(AdmuteAd(s: m.s, e: m.e, sbs: keepSbs)) }
        if verdict == "partly", let sp = span { kept.append(AdmuteAd(s: sp[0], e: sp[1], sbs: keepSbs)) }
        kept.sort { $0.s < $1.s }
        labels.ads = kept.map(\.json)
        var review = labels.review ?? [:]
        review[m.key] = AdmuteLabels.Answer(verdict: verdict, span: verdict == "partly" ? span : nil)
        labels.review = review
        edit = nil
        save()
        next()
    }

    func startFixing() {
        guard mutes.indices.contains(index) else { return }
        let m = mutes[index]
        edit = [m.s.rounded(), m.e.rounded()]
        anchors = [m.s, m.e]
    }

    func next() {
        if let after = mutes.indices.first(where: { $0 > index && answer(of: mutes[$0]) == nil }) {
            go(after)
        } else if let any = mutes.indices.first(where: { answer(of: mutes[$0]) == nil }) {
            go(any)
        } else {
            index = mutes.count
            edit = nil
        }
    }

    func go(_ i: Int) {
        index = max(0, min(i, mutes.count - 1))
        edit = nil
    }

    // ----- step 2: missed ads -----

    /// One time every 10 s of everything that played with sound, minus what's labelled.
    var missedTimes: [Int] {
        var gaps: [(Double, Double)] = []
        var t = 0.0
        for m in mutes {
            if m.s - t > 20 { gaps.append((t, m.s)) }
            t = max(t, m.e)
        }
        if length - t > 20 { gaps.append((t, length)) }
        let labelled = ads
        var out: [Int] = []
        for (a, z) in gaps {
            var x = (a / 10).rounded(.up) * 10 + 10
            while x < z - 5 {
                if !labelled.contains(where: { x >= $0.s && x < $0.e }) { out.append(Int(x)) }
                x += 10
            }
        }
        return out
    }

    func markMissed() {
        guard let t = pick else { return }
        edit = [t, t + 30]
        anchors = [t, t + 30]
    }

    func saveMissed() {
        guard let sp = edit else { return }
        var kept = ads.filter { !$0.overlaps(sp[0], sp[1]) }
        kept.append(AdmuteAd(s: sp[0], e: sp[1], sbs: false))
        kept.sort { $0.s < $1.s }
        labels.ads = kept.map(\.json)
        edit = nil
        pick = nil
        save()
    }

    func missedDone() {
        labels.missedChecked = true
        save()
    }

    // ----- fixing a span -----

    func set(_ k: Int, _ t: Double) {
        guard var sp = edit else { return }
        sp[k] = t.rounded()
        if sp[1] <= sp[0] { sp[1] = sp[0] + 5 }
        edit = sp
    }

    func nudge(_ k: Int, _ by: Double) {
        guard var sp = edit else { return }
        sp[k] = max(0, min(length, sp[k] + by))
        if sp[1] <= sp[0] { sp[1] = sp[0] + 1 }
        edit = sp
    }

    // ----- labels list -----

    func deleteAd(at i: Int) {
        var list = ads
        guard list.indices.contains(i) else { return }
        list.remove(at: i)
        labels.ads = list.map(\.json)
        save()
    }

    func toggleSbs(at i: Int) {
        var list = ads
        guard list.indices.contains(i) else { return }
        list[i].toggleSbs()
        labels.ads = list.map(\.json)
        save()
    }

    // ----- saving -----

    /// Saves the labels shortly after the last change (answers come quickly one after another).
    func save() {
        if !mutes.isEmpty { labels.reviewed = mutes.allSatisfy { answer(of: $0) != nil } }
        let snapshot = labels
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot))
                try await client.send("POST", "\(path)/labels", body: body)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Views

/// The studio's review mode, with pictures instead of video: check each mute, then look
/// for ads the detector missed.
struct AdmuteReviewView: View {
    @State private var model: AdmuteReview

    init(client: APIClient, name: String) {
        _model = State(initialValue: AdmuteReview(client: client, name: name))
    }

    var body: some View {
        Group {
            if !model.loaded {
                if let e = model.error {
                    ContentUnavailableView {
                        Label("Can't load the recording", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(e)
                    } actions: {
                        Button("Try again") { Task { await model.load() } }
                    }
                } else {
                    ProgressView()
                }
            } else if !model.surveyed {
                ContentUnavailableView("Not surveyed yet", systemImage: "waveform.badge.magnifyingglass",
                                       description: Text("Survey this recording first (swipe it in the list)."))
            } else {
                content
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.loaded && model.surveyed {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AdmuteLabelsView(model: model)
                    } label: {
                        Text("Labels")
                    }
                }
            }
        }
        .task { if !model.loaded { await model.load() } }
        .sensoryFeedback(.selection, trigger: model.index)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("Step", selection: $model.step) {
                    Text("1. Check the mutes").tag(AdmuteReview.Step.mutes)
                    Text("2. Missed ads").tag(AdmuteReview.Step.missed)
                }
                .pickerStyle(.segmented)
                if let e = model.error { ErrorBanner(message: e) }
                switch model.step {
                case .mutes: mutesStep
                case .missed: missedStep
                }
            }
            .padding()
        }
        .onChange(of: model.step) {
            model.edit = nil
            model.pick = nil
        }
        .safeAreaInset(edge: .bottom) {
            if model.step == .missed, model.edit == nil, let t = model.pick {
                HStack {
                    Text("Picture at \(AdmuteTime.hms(t))").font(.callout)
                    Spacer()
                    Button("Cancel") { model.pick = nil }
                    Button("It's an ad") { model.markMissed() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title).font(.headline)
            ProgressView(value: Double(model.checkedCount), total: Double(max(model.mutes.count, 1)))
            Text("\(model.checkedCount) of \(model.mutes.count) mutes checked"
                 + (model.wrongCount > 0 ? " · \(model.wrongCount) \(model.wrongCount == 1 ? "was" : "were") the game" : "")
                 + (model.labels.missedChecked == true ? " · missed ads checked" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Step 1

    @ViewBuilder
    private var mutesStep: some View {
        if model.mutes.isEmpty {
            Text("The survey didn't mute anything. Use step 2 to look for ads it missed.")
                .foregroundStyle(.secondary)
        } else if !model.mutes.indices.contains(model.index) {
            VStack(alignment: .leading, spacing: 12) {
                Text("All mutes checked 🎉").font(.title3.weight(.semibold))
                Text("\(model.wrongCount) of \(model.mutes.count) were the game, not ads. Next, step 2 finds ads the detector didn't mute at all.")
                Button("Look for missed ads") { model.step = .missed }
                    .buttonStyle(.borderedProminent)
                Button("Go back through the mutes") { model.go(0) }
            }
        } else {
            muteCard(model.mutes[model.index])
        }
    }

    private func muteCard(_ m: AdmuteReview.Mute) -> some View {
        let prev = model.answer(of: m)
        let span = model.edit ?? [m.s, m.e]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mute \(model.index + 1) of \(model.mutes.count)").font(.subheadline.weight(.semibold))
                if let prev {
                    Badge(text: "you said \(["right": "right", "wrong": "game", "partly": "partly"][prev.verdict] ?? prev.verdict)",
                          color: prev.verdict == "wrong" ? .red : prev.verdict == "right" ? .green : .orange)
                }
            }
            Text("\(AdmuteTime.hms(m.s)) – \(AdmuteTime.hms(m.e))")
                .font(.title2.weight(.semibold).monospacedDigit())
            + Text("  \(Format.duration(m.e - m.s)) muted").font(.subheadline).foregroundColor(.secondary)

            if model.edit != nil || m.e - m.s > 25 {
                FrameStrip(model: model, title: "Around the start", times: strip(around: model.edit != nil ? model.anchors[0] : m.s),
                           muted: span, selected: model.edit?[0]) { model.set(0, $0) }
                FrameStrip(model: model, title: "Around the end", times: strip(around: model.edit != nil ? model.anchors[1] : m.e),
                           muted: span, selected: model.edit?[1]) { model.set(1, $0) }
            } else {
                FrameStrip(model: model, title: "The mute", times: strip(from: m.s - 8, to: m.e + 8),
                           muted: span, selected: nil, onTap: nil)
            }
            Text("Red is what got muted.").font(.caption).foregroundStyle(.secondary)

            if model.edit != nil {
                FixTiming(model: model, intro: "Tap the first picture of the ad in the start pictures, and the first picture of the game coming back in the end pictures.",
                          saveTitle: "Save") { model.answer("partly", span: model.edit) }
            } else {
                VStack(spacing: 8) {
                    answerButton("Right", detail: "it was an ad", systemImage: "checkmark", tint: .green) { model.answer("right") }
                    answerButton("Wrong", detail: "it was the game", systemImage: "xmark", tint: .red) { model.answer("wrong") }
                    answerButton("Partly", detail: "an ad, but it starts or ends at the wrong time", systemImage: "circle.lefthalf.filled",
                                 tint: .orange) { model.startFixing() }
                }
            }
            HStack {
                Button { model.go(model.index - 1) } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(model.index == 0)
                Spacer()
                Button { model.go(model.index + 1) } label: { Label("Skip", systemImage: "chevron.right").labelStyle(.titleAndIcon) }
                    .disabled(model.index >= model.mutes.count - 1)
            }
        }
    }

    private func answerButton(_ title: String, detail: String, systemImage: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).font(.headline)
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).opacity(0.85)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    /// Times every 2 s within 10 s either side of t.
    private func strip(around t: Double) -> [Double] { strip(from: t - 10, to: t + 10) }

    private func strip(from a: Double, to b: Double) -> [Double] {
        let lo = max(0, (a / 2).rounded(.down) * 2), hi = min(model.length, b)
        guard hi > lo else { return [lo] }
        return Array(stride(from: lo, through: hi, by: 2))
    }

    // MARK: Step 2

    @ViewBuilder
    private var missedStep: some View {
        if model.edit != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mark the missed ad").font(.title3.weight(.semibold))
                FrameStrip(model: model, title: "Around the start", times: strip(around: model.anchors[0]),
                           muted: model.edit, selected: model.edit?[0]) { model.set(0, $0) }
                FrameStrip(model: model, title: "Around the end", times: strip(around: model.anchors[1]),
                           muted: model.edit, selected: model.edit?[1]) { model.set(1, $0) }
                FixTiming(model: model, intro: "Tap the first picture of the ad, and the first picture of the game coming back.",
                          saveTitle: "Save ad") { model.saveMissed() }
            }
        } else {
            let times = model.missedTimes
            VStack(alignment: .leading, spacing: 12) {
                Text("Anything the detector didn't mute? One picture every 10 seconds of everything that played with sound. Tap one that looks like an ad.")
                    .font(.callout).foregroundStyle(.secondary)
                if times.isEmpty {
                    Text("Nothing unmuted to check.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                    ForEach(times, id: \.self) { t in
                        Button {
                            model.pick = Double(t)
                        } label: {
                            VStack(spacing: 2) {
                                FrameImage(model: model, t: Double(t))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(model.pick == Double(t) ? Color.accentColor : Color.clear, lineWidth: 3))
                                Text(AdmuteTime.hms(Double(t))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    model.missedDone()
                } label: {
                    Label(model.labels.missedChecked == true ? "Checked" : "Done: no more missed ads",
                          systemImage: model.labels.missedChecked == true ? "checkmark.circle.fill" : "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.labels.missedChecked == true)
            }
        }
    }
}

/// One exact frame of the recording (the studio's /thumb, 192×108, cached on the server).
struct FrameImage: View {
    let model: AdmuteReview
    let t: Double

    var body: some View {
        ServerImage(client: model.client, path: "\(model.path)/thumb", contentMode: .fit,
                    query: [URLQueryItem(name: "t", value: String(Int(t)))])
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A row of frames; red marks what's muted, tapping one picks its time.
struct FrameStrip: View {
    let model: AdmuteReview
    let title: String
    let times: [Double]
    let muted: [Double]?
    let selected: Double?
    var onTap: ((Double) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(times, id: \.self) { t in
                        let isMuted = muted.map { t >= $0[0] && t < $0[1] } ?? false
                        VStack(spacing: 2) {
                            FrameImage(model: model, t: t)
                                .frame(width: 112)
                                .overlay {
                                    if isMuted { Color.red.opacity(0.3).clipShape(RoundedRectangle(cornerRadius: 4)) }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(selected == t ? Color.accentColor : Color.clear, lineWidth: 3))
                            Text(AdmuteTime.hms(t)).font(.caption2.monospacedDigit())
                                .foregroundStyle(isMuted ? Color.red : Color.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onTap?(t) }
                    }
                }
            }
            .defaultScrollAnchor(.center)
        }
    }
}

/// The start and end being fixed, with ±1 s and ±5 s steps, and Save / Cancel.
struct FixTiming: View {
    let model: AdmuteReview
    let intro: String
    let saveTitle: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(intro).font(.callout)
            if let sp = model.edit {
                row("Ad starts", sp[0], k: 0)
                row("Game back", sp[1], k: 1)
            }
            HStack {
                Button(saveTitle, action: onSave)
                    .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    model.edit = nil
                    model.pick = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ t: Double, k: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.subheadline)
            Spacer()
            Button("−5") { model.nudge(k, -5) }
            Button("−1") { model.nudge(k, -1) }
            Text(AdmuteTime.hms(t)).font(.body.monospacedDigit()).frame(minWidth: 64)
            Button("+1") { model.nudge(k, 1) }
            Button("+5") { model.nudge(k, 5) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// Every label on the recording: delete, mark side-by-side, notes.
struct AdmuteLabelsView: View {
    let model: AdmuteReview
    @State private var notes = ""

    var body: some View {
        List {
            Section {
                let ads = model.ads
                if ads.isEmpty {
                    Text("No labels yet. Answering the review adds them.").foregroundStyle(.secondary)
                }
                ForEach(Array(ads.enumerated()), id: \.offset) { i, ad in
                    HStack {
                        Text("\(AdmuteTime.hms(ad.s)) – \(AdmuteTime.hms(ad.e))").monospacedDigit()
                        Text(Format.duration(ad.e - ad.s)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if ad.sbs { Badge(text: "side-by-side", color: .purple) }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.deleteAd(at: i) }
                        Button(ad.sbs ? "Not SbS" : "SbS") { model.toggleSbs(at: i) }.tint(.purple)
                    }
                }
            } header: {
                Text("Ads")
            } footer: {
                Text("Swipe a label to delete it, or to mark it as a side-by-side ad (the game in a small box next to an ad) so the studio can learn the layout.")
            }
            Section("Notes") {
                TextField("e.g. 1:43:04 promo over crowd shot", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .onSubmit(saveNotes)
            }
            Section {
                LabeledContent("Mutes checked", value: "\(model.checkedCount) of \(model.mutes.count)")
                LabeledContent("Missed ads checked", value: model.labels.missedChecked == true ? "Yes" : "No")
                LabeledContent("Counts as reviewed", value: model.labels.reviewed == true ? "Yes" : "No")
            } footer: {
                Text("A recording counts as reviewed once every mute is checked; reviewed games are used to score settings and to train the scene check.")
            }
        }
        .navigationTitle("Labels")
        .onAppear { notes = model.labels.notes ?? "" }
        .onDisappear(perform: saveNotes)
    }

    private func saveNotes() {
        guard notes != (model.labels.notes ?? "") else { return }
        model.labels.notes = notes
        model.save()
    }
}
