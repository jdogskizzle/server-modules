import SwiftUI

@MainActor @Observable
final class MinerStore {
    let client: APIClient
    var status: MinerStatus?
    var error: String?
    var sending = false

    init(client: APIClient) { self.client = client }

    func refresh() async {
        do {
            status = try await client.get("api/status")
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// POST /api/control: {"paused": Bool}, {"pin": key or ""}, {"check": true},
    /// {"power_mode": mode}, {"benchmark": key}, {"benchmark_cancel": true},
    /// {"power_price": $/kWh or null for the .env default}.
    func control(_ body: JSONObject) async {
        sending = true
        defer { sending = false }
        do {
            try await client.send("POST", "api/control", body: .object(body))
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MinerView: View {
    @State private var store: MinerStore
    @State private var confirm: Confirm?
    @State private var editingRate = false
    @State private var rateText = ""

    init(client: APIClient) {
        _store = State(initialValue: MinerStore(client: client))
    }

    /// An action waiting for the user to confirm it.
    struct Confirm: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let button: String
        let body: JSONObject
    }

    var body: some View {
        Group {
            Group {
                if let s = store.status {
                    content(s)
                } else if let e = store.error {
                    ContentUnavailableView {
                        Label("Can't reach the miner", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(e)
                    } actions: {
                        Button("Try again") { Task { await store.refresh() } }
                    }
                } else {
                    ProgressView("Loading…")
                }
            }
            .navigationTitle("Miner")
            .refreshable { await store.refresh() }
            .polling(every: 5) { await store.refresh() }
            .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                   presenting: confirm) { c in
                Button(c.button) { Task { await store.control(c.body) } }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                Text(c.message)
            }
        }
    }

    // MARK: - Sections

    private func content(_ s: MinerStatus) -> some View {
        List {
            if let e = store.error {
                Section { ErrorBanner(message: e) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section { header(s) }
            Section {
                stats(s)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section("Control") { controls(s) }
            benchmarkSection(s)
            Section {
                modes(s)
            } header: {
                Text("Power mode")
            } footer: {
                Text(modeNote(s))
            }
            if s.power != nil {
                Section {
                    power(s)
                } header: {
                    Text("Power cost")
                } footer: {
                    Text(powerNote(s))
                }
            }
            Section {
                coins(s)
            } header: {
                Text("Coins")
            } footer: {
                Text("Estimates are for the current power mode. Swipe or long-press a coin to pin or benchmark it.")
            }
        }
        .listStyle(.insetGrouped)
        .alert("Electricity price", isPresented: $editingRate) {
            TextField("¢/kWh", text: $rateText).keyboardType(.decimalPad)
            Button("Save") { saveRate() }
            if s.control?.powerPrice != nil, s.power?.envRate != nil {
                Button("Use the .env price") { Task { await store.control(["power_price": .null]) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In cents per kWh, the energy charge only (e.g. 13.38).")
        }
    }

    // MARK: Power cost

    @ViewBuilder
    private func power(_ s: MinerStatus) -> some View {
        let rate = s.power?.rate
        if s.hashing, s.watchdog?.state == "mining", let est = s.live?["miner_est_usd_per_day"],
           let cost = s.powerPerDay(s.live?["gpu_power_watts"]) {
            LabeledContent("Now, after power") {
                Text(Format.usd(est - cost) + "/day").monospacedDigit()
            }
        }
        ForEach(MinerStatus.powerWindows, id: \.key) { w in
            let win = s.power?.windows?[w.key]
            let cost: Double? = rate.flatMap { r in win?.kwh.map { $0 * r } }
            let net: Double? = cost.flatMap { c in win?.earned.map { $0 - c } }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(w.label)
                    Spacer()
                    Text(net.map { "Net " + Format.usd($0) } ?? "–")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(net.map { $0 < 0 ? Color.red : Color.green } ?? Color.secondary)
                }
                Text("\(Format.number(win?.kwh, digits: 1)) kWh · cost \(Format.usd(cost)) · earned \(Format.usd(win?.earned))"
                     + (win?.miningS.map { " · mined \(Format.duration($0))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Button {
            rateText = rate.map { String(format: "%.2f", $0 * 100) } ?? ""
            editingRate = true
        } label: {
            LabeledContent("Electricity", value: rate.map { String(format: "%.2f¢/kWh", $0 * 100) } ?? "Not set")
        }
        .disabled(store.sending)
    }

    private func powerNote(_ s: MinerStatus) -> String {
        var note = s.power?.rate == nil
            ? "Set the electricity price to see the cost. "
            : s.power?.rateSource == "panel" ? "Price set in the panel. " : "Price from the miner's .env. "
        note += "Energy is the GPU's while mining; earnings are estimates."
        if let since = s.power?.since { note += " Recording began \(Format.ago(since, now: s.now))." }
        return note
    }

    private func saveRate() {
        let text = rateText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let cents = Double(text), (0...500).contains(cents) else {
            store.error = "Enter a price in cents per kWh, between 0 and 500."
            return
        }
        Task { await store.control(["power_price": .number(cents / 100)]) }
    }

    private struct StateLook {
        let color: Color
        let text: String
    }

    private func stateLook(_ s: MinerStatus) -> StateLook {
        let w = s.watchdog
        let act = s.active
        let coin = act?.coin.map { "\(act?.name ?? $0) (\($0))" } ?? "no coin yet"
        let now = s.now
        var look: StateLook
        switch w?.state {
        case "mining": look = StateLook(color: .green, text: "Mining \(coin)")
        case "benchmarking": look = StateLook(color: .purple, text: "Benchmarking \(s.coinName(s.benchmark?.coin))")
        case "paused": look = StateLook(color: .orange, text: "Paused")
        case "yielded": look = StateLook(color: .blue, text: "Paused for another app")
        case "cooling": look = StateLook(color: .blue, text: "Resuming in \(Format.duration((w?.resumeAt ?? now) - now))")
        case "waiting": look = StateLook(color: .gray, text: "Waiting for a coin")
        case "disabled": look = StateLook(color: .gray, text: "Disabled")
        case "stopped": look = StateLook(color: .red, text: "Watchdog not running")
        default: look = StateLook(color: .gray, text: "Unknown")
        }
        // The watchdog says "mining" once it started the miner; trust the miner's own report too.
        if w?.state == "mining", s.live != nil, (s.live?["miner_up"] ?? 0) == 0 {
            look = StateLook(color: .orange, text: "Starting \(coin)…")
        }
        if s.paused, w?.state != "paused", w?.state != "disabled" {
            look = StateLook(color: look.color, text: look.text + " (pausing…)")
        }
        return look
    }

    private func header(_ s: MinerStatus) -> some View {
        let look = stateLook(s)
        let w = s.watchdog
        let act = s.active
        var reason = ""
        if w?.state == "mining", let mode = act?.powerMode {
            reason = (act?.tuned ?? false) ? Format.capitalized(mode) + " mode" : "not benchmarked yet"
        } else {
            reason = w?.reason ?? ""
        }
        if let since = w?.since, w?.state != "cooling" {
            reason += (reason.isEmpty ? "" : " · ") + "since " + Format.ago(since, now: s.now)
        }
        return HStack(spacing: 12) {
            StatusDot(color: look.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(look.text).font(.headline)
                if !reason.isEmpty {
                    Text(reason).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stats(_ s: MinerStatus) -> some View {
        let live = s.live ?? [:]
        let mining = s.hashing
        return StatGrid {
            StatTile(title: "Hashrate", value: mining ? Format.hashrate(live["miner_hashrate_hs"]) : "–",
                     systemImage: "speedometer")
            StatTile(title: "Estimated", value: mining && s.watchdog?.state == "mining"
                        ? Format.usd(live["miner_est_usd_per_day"]) + "/day" : "–",
                     systemImage: "dollarsign.circle", tint: .green)
            StatTile(title: "GPU power", value: live["gpu_power_watts"].map {
                        "\(Int($0.rounded())) / \(Int((live["gpu_power_limit_watts"] ?? 0).rounded())) W" } ?? "–",
                     systemImage: "bolt.fill", tint: .yellow)
            StatTile(title: "Temp / fan", value: live["gpu_temperature_celsius"].map {
                        "\(Int($0.rounded()))°C / \(Int((live["gpu_fan_percent"] ?? 0).rounded()))%" } ?? "–",
                     systemImage: "thermometer.medium", tint: .red)
            StatTile(title: "Shares (ok / rejected)", value: mining
                        ? "\(Int(live["miner_shares_accepted"] ?? 0)) / \(Int(live["miner_shares_rejected"] ?? 0))" : "–",
                     systemImage: "checkmark.seal")
            StatTile(title: "On this coin", value: s.active?.since.map { Format.duration(s.now - $0) } ?? "–",
                     systemImage: "clock")
        }
    }

    @ViewBuilder
    private func controls(_ s: MinerStatus) -> some View {
        let disabled = s.watchdog?.state == "disabled"
        Button {
            Task { await store.control(["paused": .bool(!s.paused)]) }
        } label: {
            Label(s.paused ? "Resume mining" : "Pause mining",
                  systemImage: s.paused ? "play.fill" : "pause.fill")
        }
        .disabled(disabled)
        Text(disabled ? "Turned off in .env (MINING_ENABLED)"
             : s.paused ? "Stays paused until you resume, even after a restart"
             : "Other apps still take over the GPU automatically")
            .font(.caption).foregroundStyle(.secondary)

        Menu {
            Button {
                ask(s, pin: "")
            } label: {
                if s.pin.isEmpty { Label("Automatic (best paying)", systemImage: "checkmark") }
                else { Text("Automatic (best paying)") }
            }
            Divider()
            ForEach(s.coins) { c in
                Button {
                    ask(s, pin: c.key)
                } label: {
                    if s.pin == c.key { Label("\(c.name) (\(c.key))", systemImage: "checkmark") }
                    else { Text("\(c.name) (\(c.key))") }
                }
            }
        } label: {
            LabeledContent("Coin") {
                Text(s.pin.isEmpty ? "Automatic" : s.coinName(s.pin))
            }
        }
        Text(coinNote(s)).font(.caption).foregroundStyle(.secondary)

        Button {
            Task { await store.control(["check": true]) }
        } label: {
            Label("Compare prices now", systemImage: "arrow.triangle.2.circlepath")
        }
        Text(checkNote(s)).font(.caption).foregroundStyle(.secondary)
    }

    private func coinNote(_ s: MinerStatus) -> String {
        if !s.pin.isEmpty {
            return s.active?.coin == s.pin ? "Pinned" : "Switching to \(s.coinName(s.pin))…"
        }
        if let p = s.configPin, !p.isEmpty { return "Pinned to \(p) in coins.toml" }
        return "The switcher picks the best-paying coin"
    }

    private func checkNote(_ s: MinerStatus) -> String {
        let est = s.estimates
        if let asked = s.control?.checkRequested, (est?.updated ?? 0) < asked { return "Checking…" }
        guard let est, let updated = est.updated else { return "No prices yet" }
        var t = "Last \(Format.ago(updated, now: s.now))"
        if let next = est.nextCheck { t += ", next in \(Format.duration(next - s.now))" }
        return t
    }

    private func ask(_ s: MinerStatus, pin key: String) {
        guard key != s.pin else { return }
        if key.isEmpty {
            confirm = Confirm(title: "Switch to automatic?", message: "The switcher goes back to picking the best-paying coin (it won't switch right away).",
                              button: "Automatic", body: ["pin": ""])
            return
        }
        var msg = "Estimated \(Format.usd(s.estimate(key)?.usdDay))/day in the current mode"
        if let cur = s.active?.coin, cur != key {
            msg += " (now \(Format.usd(s.estimate(cur)?.usdDay))/day on \(s.coinName(cur)))"
        }
        msg += ". The miner switches right away and stays on it until you unpin."
        confirm = Confirm(title: "Pin \(s.coinName(key))?", message: msg, button: "Pin", body: ["pin": .string(key)])
    }

    // MARK: Power modes

    @ViewBuilder
    private func modes(_ s: MinerStatus) -> some View {
        let key = s.active?.coin ?? s.coins.first?.key
        let est = s.estimate(key)?.modes ?? [:]
        let tuned = key.flatMap { s.tuning?[$0]?.modes } ?? [:]
        let current = s.currentMode
        let base = est[current]?.usdDay
        ForEach(MinerStatus.modes, id: \.self) { m in
            let r = est[m]
            let t = tuned[m]
            Button {
                guard m != current else { return }
                var msg = "Applies in a few seconds, no restart."
                if let name = s.active?.name, let from = base, let to = r?.usdDay {
                    msg = "\(name): \(Format.usd(from)) → \(Format.usd(to))/day. " + msg
                }
                confirm = Confirm(title: "Switch to \(Format.capitalized(m)) mode?", message: msg,
                                  button: "Switch", body: ["power_mode": .string(m)])
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: m == current ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(m == current ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.capitalized(m)).foregroundStyle(.primary)
                        Text(MinerStatus.modeInfo[m] ?? "").font(.caption).foregroundStyle(.secondary)
                        if let t {
                            Text("core \(clock(r?.coreClock ?? t.coreClock)), memory \(clock(r?.memClock ?? t.memClock))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.usd(r?.usdDay)).font(.body.monospacedDigit()).foregroundStyle(.primary)
                        let power = r?.power ?? t?.power
                        Text("\(Format.hashrate(r?.hashrate))\(power.map { " · \(Int($0.rounded())) W" } ?? "")")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if m != current, let b = base, let v = r?.usdDay {
                            let d = v - b
                            Text((d >= 0 ? "+" : "−") + Format.usd(abs(d)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(d >= 0 ? Color.green : Color.red)
                        }
                    }
                }
            }
        }
    }

    private func clock(_ v: JSONValue?) -> String {
        guard let n = v?.double, n > 0 else { return "auto" }
        return "\(Int(n)) MHz"
    }

    private func modeNote(_ s: MinerStatus) -> String {
        guard let key = s.active?.coin ?? s.coins.first?.key else { return "" }
        var note = "The mode applies to every coin."
        if s.tuning?[key]?.modes == nil {
            note = "\(s.coinName(key)) isn't benchmarked yet, so every mode runs on its default settings. " + note
        }
        if let m = s.active?.powerMode, m != s.currentMode { note += " Applying…" }
        return note
    }

    // MARK: Benchmark

    @ViewBuilder
    private func benchmarkSection(_ s: MinerStatus) -> some View {
        switch s.benchState {
        case .queued(let coin):
            Section("Benchmark") {
                Label("\(s.coinName(coin)) benchmark queued", systemImage: "hourglass")
                cancelBenchmark
            }
        case .running(let coin):
            let b = s.benchmark
            Section("Benchmark") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Benchmarking \(s.coinName(coin))").font(.headline)
                    if let step = b?.step, let steps = b?.steps, steps > 0 {
                        ProgressView(value: min(step, steps), total: steps)
                        Text("Setting \(Int(step)) of \(Int(steps))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let m = b?.message, !m.isEmpty { Text(m).font(.caption).foregroundStyle(.secondary) }
                    if let started = b?.started {
                        Text("Started \(Format.ago(started, now: s.now))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                cancelBenchmark
            }
        case .idle:
            if let b = s.benchmark, let status = b.status, let updated = b.updated, s.now - updated < 6 * 3600 {
                Section("Last benchmark") {
                    LabeledContent(s.coinName(b.coin), value: Format.capitalized(status))
                    if let m = b.message, !m.isEmpty { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var cancelBenchmark: some View {
        Button("Cancel benchmark", role: .destructive) {
            Task { await store.control(["benchmark_cancel": true]) }
        }
    }

    // MARK: Coins

    @ViewBuilder
    private func coins(_ s: MinerStatus) -> some View {
        let ranked = s.coins.sorted { (s.estimate($0.key)?.usdDay ?? -1) > (s.estimate($1.key)?.usdDay ?? -1) }
        let best = ranked.first { s.estimate($0.key)?.usdDay != nil && (s.estimate($0.key)?.liquid ?? true) }
        let pin = s.pin.isEmpty ? (s.configPin ?? "") : s.pin
        ForEach(ranked) { c in
            let e = s.estimate(c.key)
            let t = s.tuning?[c.key]
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(c.name).font(.body.weight(.semibold))
                    Text(c.key).font(.caption).foregroundStyle(.secondary)
                    if c.key == s.active?.coin {
                        Badge(text: s.watchdog?.state == "mining" ? "mining" : "active", color: .green)
                    }
                    if c.key == pin { Badge(text: "pinned", color: .purple) }
                    if c.key == best?.key, c.key != s.active?.coin { Badge(text: "best", color: .blue) }
                    if e?.usdDay != nil, e?.liquid == false { Badge(text: "thin market", color: .orange) }
                    Spacer()
                    Text(Format.usd(e?.usdDay)).font(.body.monospacedDigit())
                }
                HStack {
                    Text("\(c.algorithm) · \(tuneNote(s, key: c.key, tuning: t))")
                    Spacer()
                    Text("\(Format.hashrate(e?.hashrate)) · \(Format.price(e?.priceUsd))")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .swipeActions(edge: .trailing) { coinActions(s, c, tuning: t) }
            .contextMenu { coinActions(s, c, tuning: t) }
        }
    }

    @ViewBuilder
    private func coinActions(_ s: MinerStatus, _ c: MinerStatus.Coin, tuning t: MinerStatus.Tuning?) -> some View {
        if s.pin == c.key {
            Button("Unpin") { ask(s, pin: "") }.tint(.gray)
        } else {
            Button("Pin") { ask(s, pin: c.key) }.tint(.purple)
        }
        if !s.benchBusy {
            Button(t?.modes != nil ? "Re-benchmark" : "Benchmark") {
                confirm = Confirm(title: "Benchmark \(c.name)?",
                                  message: "The miner switches to \(c.name) for about 10 minutes while it tries different clock settings (it keeps earning).",
                                  button: "Benchmark", body: ["benchmark": .string(c.key)])
            }
            .tint(.blue)
        }
    }

    private func tuneNote(_ s: MinerStatus, key: String, tuning t: MinerStatus.Tuning?) -> String {
        switch s.benchState {
        case .running(let c) where c == key: return "benchmarking now"
        case .queued(let c) where c == key: return "benchmark queued"
        default: break
        }
        if t?.modes != nil, let at = t?.benchmarked { return "benchmarked " + Format.ago(at, now: s.now) }
        if let e = t?.error { return "benchmark " + (e.split(separator: ":").first.map(String.init) ?? e) }
        return "not benchmarked"
    }
}
