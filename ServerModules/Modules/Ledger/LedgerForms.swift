import SwiftUI

/// Add or edit a row of any ledger table.
struct LedgerRowForm: View {
    let store: LedgerStore
    let table: LedgerTable
    let row: LedgerRow?
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var item = ""
    @State private var category = "server"
    @State private var cost = ""
    @State private var fromFund = ""
    @State private var outOfPocket = ""
    @State private var amount = ""
    @State private var currency = "BTC"
    @State private var usd = ""
    @State private var priority = 5
    @State private var link = ""
    @State private var notes = ""
    @State private var status = LedgerStatus.active
    @State private var statusDate = Date()
    @State private var soldPrice = ""
    @State private var clearImage = false
    @State private var loaded = false
    @State private var working = false
    @State private var lookingUp = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var hasStatus: Bool { table == .investments || table == .purchases }

    var body: some View {
        Form {
            switch table {
            case .income: incomeFields
            case .purchases, .investments, .wishlist: itemFields
            }
            Section("Notes") {
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...5)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if row != nil {
                Section {
                    Button("Delete \(table.singular)", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(row == nil ? "Add \(table.singular)" : "Edit \(table.singular)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(working || !valid)
            }
        }
        .confirmationDialog("Delete this \(table.singular)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if let row { await store.delete(table, id: row.id) }
                    dismiss()
                }
            }
        }
        .onAppear(perform: fill)
    }

    // MARK: Fields

    @ViewBuilder
    private var incomeFields: some View {
        Section {
            DatePicker("Date", selection: $date, displayedComponents: .date)
            HStack {
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                Picker("", selection: $currency) {
                    Text("BTC").tag("BTC")
                    Text("USD").tag("USD")
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                TextField("USD value", text: $usd).keyboardType(.decimalPad)
                if currency == "BTC" {
                    Button {
                        Task { await lookUpPrice() }
                    } label: {
                        if lookingUp { ProgressView() } else { Text("Price on date") }
                    }
                    .disabled(lookingUp || Double(amount) == nil)
                }
            }
        } header: {
            Text("Payout")
        } footer: {
            Text("A BTC payout is valued at CoinGecko's price on the payout date. Each payout is split between payback and the fund.")
        }
    }

    @ViewBuilder
    private var itemFields: some View {
        Section {
            TextField("Item", text: $item)
            TextField("Category", text: $category)
                .textInputAutocapitalization(.never)
            if table == .wishlist {
                TextField("Estimated cost (USD)", text: $cost).keyboardType(.decimalPad)
                Stepper("Priority \(priority)", value: $priority, in: 1...99)
            } else {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Cost (USD)", text: $cost).keyboardType(.decimalPad)
            }
            TextField("Product link", text: $link)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } footer: {
            if table == .wishlist { Text("Lower numbers come first; the fund goes to them first.") }
        }
        if table == .purchases {
            Section {
                TextField("From the fund", text: $fromFund).keyboardType(.decimalPad)
                TextField("Out of pocket", text: $outOfPocket).keyboardType(.decimalPad)
            } header: {
                Text("Paid with")
            } footer: {
                Text("Leave both blank to take as much as possible from the fund. What's paid out of pocket is added to the payback.")
            }
        }
        if hasStatus {
            Section("Hardware status") {
                Picker("Status", selection: $status) {
                    ForEach(LedgerStatus.allCases) { Text($0.label).tag($0) }
                }
                if status != .active {
                    DatePicker("Since", selection: $statusDate, displayedComponents: .date)
                }
                if status == .sold {
                    TextField("Sold for (USD)", text: $soldPrice).keyboardType(.decimalPad)
                }
            }
        }
        Section {
            if let img = row?.image, !img.isEmpty, !clearImage {
                HStack {
                    LedgerThumb(client: store.client, image: img, size: 64)
                    Spacer()
                    Button("Remove picture", role: .destructive) { clearImage = true }
                }
            } else {
                Text(row == nil ? "A picture is found automatically from the product page or an image search."
                     : "No picture. Changing the item or link looks for one again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Load / save

    private var valid: Bool {
        switch table {
        case .income: return Double(usd) != nil
        case .wishlist: return !item.trimmingCharacters(in: .whitespaces).isEmpty && Double(cost) != nil
        case .purchases, .investments:
            return !item.trimmingCharacters(in: .whitespaces).isEmpty && Double(cost) != nil
                && (status != .sold || Double(soldPrice) != nil)
        }
    }

    private func fill() {
        guard !loaded else { return }
        loaded = true
        guard let r = row else { return }
        func num(_ v: Double?) -> String { v.map { $0 == $0.rounded() && table != .income ? String(Int($0)) : String($0) } ?? "" }
        if let d = r.date.flatMap({ Format.isoDay.date(from: $0) }) { date = d }
        item = r.item ?? ""
        category = r.category ?? "server"
        cost = num(table == .wishlist ? r.estCost : r.cost)
        fromFund = num(r.fromFund)
        outOfPocket = num(r.outOfPocket)
        amount = r.amount.map { String($0) } ?? ""
        currency = r.currency ?? "BTC"
        usd = num(r.usd)
        priority = r.priority ?? 5
        link = r.link ?? ""
        notes = r.notes ?? ""
        status = r.status.flatMap(LedgerStatus.init(rawValue:)) ?? .active
        if let d = r.statusDate.flatMap({ Format.isoDay.date(from: $0) }) { statusDate = d }
        soldPrice = num(r.soldPrice)
    }

    private func number(_ s: String) -> JSONValue {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(t).map { .number($0) } ?? .null
    }

    private func requestBody() -> JSONObject {
        var b: JSONObject = ["notes": .string(notes)]
        switch table {
        case .income:
            b["date"] = .string(Format.isoString(date))
            b["amount"] = number(amount)
            b["currency"] = .string(currency)
            b["usd"] = number(usd)
        case .wishlist:
            b["item"] = .string(item)
            b["category"] = .string(category)
            b["est_cost"] = number(cost)
            b["priority"] = .number(Double(priority))
            b["link"] = .string(link)
        case .purchases, .investments:
            b["date"] = .string(Format.isoString(date))
            b["item"] = .string(item)
            b["category"] = .string(category)
            b["cost"] = number(cost)
            b["link"] = .string(link)
            b["status"] = .string(status.rawValue)
            b["status_date"] = status == .active ? .string("") : .string(Format.isoString(statusDate))
            b["sold_price"] = status == .sold ? number(soldPrice) : .null
            if table == .purchases {
                // Blank means "work it out": leave the key out so the server fills it in.
                if case .number = number(fromFund) { b["from_fund"] = number(fromFund) }
                if case .number = number(outOfPocket) { b["out_of_pocket"] = number(outOfPocket) }
            }
        }
        if clearImage { b["image_clear"] = true }
        return b
    }

    private func save() async {
        working = true
        defer { working = false }
        let payload = JSONValue.object(requestBody())
        do {
            try await store.change(table) {
                if let row {
                    try await store.client.send("PUT", "api/\(table.rawValue)/\(row.id)", body: payload)
                } else {
                    try await store.client.send("POST", "api/\(table.rawValue)", body: payload)
                }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func lookUpPrice() async {
        lookingUp = true
        defer { lookingUp = false }
        struct Price: Decodable { let usd: Double }
        do {
            let p = try await store.client.get("api/price/btc", query: [URLQueryItem(name: "date", value: Format.isoString(date))],
                                               as: Price.self)
            if let a = Double(amount.replacingOccurrences(of: ",", with: ".")) {
                usd = String(format: "%.2f", a * p.usd)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Turn a wishlist item into a purchase.
struct LedgerBuyForm: View {
    let store: LedgerStore
    let wish: LedgerSummary.WishItem
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var cost = ""
    @State private var fromFund = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text(wish.item)
                DatePicker("Bought on", selection: $date, displayedComponents: .date)
                TextField("Paid (USD)", text: $cost).keyboardType(.decimalPad)
                TextField("From the fund (blank = as much as possible)", text: $fromFund).keyboardType(.decimalPad)
            } footer: {
                Text("Fund balance: \(Format.usd(store.summary?.fund)). The rest counts as out of pocket and is added to the payback.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Bought it")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(working || Double(cost) == nil)
            }
        }
        .onAppear {
            if cost.isEmpty, let c = wish.estCost { cost = c == c.rounded() ? String(Int(c)) : String(c) }
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        var payload: JSONObject = ["date": .string(Format.isoString(date))]
        if let c = Double(cost) { payload["cost"] = .number(c) }
        if let f = Double(fromFund) { payload["from_fund"] = .number(f) }
        do {
            try await store.change(.purchases) {
                try await store.client.send("POST", "api/wishlist/\(wish.id)/buy", body: .object(payload))
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LedgerShareForm: View {
    let store: LedgerStore
    @State var share: Double
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("\(Int((share * 100).rounded()))% to payback, \(100 - Int((share * 100).rounded()))% to the fund")
                    Slider(value: $share, in: 0...1, step: 0.05)
                }
            } footer: {
                Text("The share of each payout that goes to paying back what the server cost. Once it's paid back, everything goes to the fund. Changing this re-splits past payouts.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Payback share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        do {
                            try await store.change(nil) {
                                try await store.client.send("PUT", "api/settings", body: ["payback_share": .number(share)])
                            }
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

struct ServerSpecsView: View {
    let client: APIClient
    @State private var specs: ServerSpecs?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Section { ErrorBanner(message: error) } }
            if let s = specs {
                Section("System") {
                    if let c = s.cpu {
                        LabeledContent("CPU", value: c.model ?? "–")
                        LabeledContent("Cores / threads", value: "\(c.cores.map(String.init) ?? "?") / \(c.threads.map(String.init) ?? "?")"
                                       + (c.maxGhz.map { " · up to \(Format.number($0, digits: 1)) GHz" } ?? ""))
                    }
                    if let m = s.memory {
                        LabeledContent("Memory", value: "\(Format.number(m.installedGb)) GB (\(Format.number(m.usableGib, digits: 1)) GiB usable)")
                    }
                    if let b = s.board {
                        LabeledContent("Motherboard", value: [b.vendor, b.name].compactMap { $0 }.joined(separator: " "))
                        if let bios = b.bios, !bios.isEmpty { LabeledContent("BIOS", value: bios) }
                    }
                    if let sys = s.system {
                        if let os = sys.os { LabeledContent("OS", value: os) }
                        if let k = sys.kernel { LabeledContent("Kernel", value: k) }
                        if let up = sys.uptimeDays { LabeledContent("Uptime", value: "\(Format.number(up, digits: 1)) days") }
                    }
                }
                if let gpus = s.gpus, !gpus.isEmpty {
                    Section("Graphics") {
                        ForEach(gpus, id: \.self) { g in
                            LabeledContent([g.vendor, g.name].compactMap { $0 }.joined(separator: " "),
                                           value: g.integrated == true ? "integrated" : (g.vram ?? ""))
                        }
                    }
                }
                if let nics = s.network, !nics.isEmpty {
                    Section("Network") {
                        ForEach(nics, id: \.self) { n in
                            LabeledContent([n.vendor, n.name].compactMap { $0 }.joined(separator: " "),
                                           value: [n.wifi == true ? "Wi-Fi" : nil, n.link].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
                if let st = s.storage {
                    if !st.arrays.isEmpty {
                        Section("RAID") {
                            ForEach(st.arrays, id: \.self) { a in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text("\(a.name) · \(a.level ?? "") · \(a.size ?? "")")
                                        Spacer()
                                        Badge(text: a.healthy == true ? "healthy" : "degraded",
                                              color: a.healthy == true ? .green : .red)
                                    }
                                    Text((a.disks ?? []).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                    mounts(a.mounts)
                                }
                            }
                        }
                    }
                    Section("Disks") {
                        ForEach(st.disks, id: \.self) { d in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(d.model ?? d.name)
                                    Spacer()
                                    Text(d.size ?? "").foregroundStyle(.secondary)
                                }
                                Text([d.type, d.name, d.array.map { "in \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                mounts(d.mounts)
                            }
                        }
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Server specs")
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func mounts(_ list: [ServerSpecs.Mount]?) -> some View {
        ForEach(list ?? [], id: \.self) { m in
            if let size = m.size, size > 0 {
                let used = size - (m.avail ?? 0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(m.mount).font(.caption.monospaced())
                        Spacer()
                        Text("\(Format.bytes(m.avail)) free of \(Format.bytes(size))").font(.caption2).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(max(used, 0), size), total: size)
                }
            }
        }
    }

    private func load() async {
        do {
            specs = try await client.get("api/server/specs")
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
