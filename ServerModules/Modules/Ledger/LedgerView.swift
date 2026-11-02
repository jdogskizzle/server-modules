import SwiftUI

@MainActor @Observable
final class LedgerStore {
    let client: APIClient
    var summary: LedgerSummary?
    var rows: [LedgerTable: [LedgerRow]] = [:]
    var error: String?

    init(client: APIClient) { self.client = client }

    func refresh() async {
        do {
            summary = try await client.get("api/summary")
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func load(_ table: LedgerTable) async {
        do {
            rows[table] = try await client.get("api/\(table.rawValue)", as: [LedgerRow].self)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Runs a change, then reloads the summary (and a table). Throws so forms can show the error.
    func change(_ table: LedgerTable?, _ op: () async throws -> Void) async throws {
        try await op()
        await refresh()
        if let table { await load(table) }
    }

    func delete(_ table: LedgerTable, id: Int) async {
        do {
            try await change(table) { try await self.client.send("DELETE", "api/\(table.rawValue)/\(id)") }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LedgerView: View {
    @State private var store: LedgerStore
    @State private var editing: LedgerEdit?
    @State private var buying: LedgerSummary.WishItem?
    @State private var showShare = false

    init(client: APIClient) {
        _store = State(initialValue: LedgerStore(client: client))
    }

    var body: some View {
        Group {
            List {
                if let e = store.error {
                    Section { ErrorBanner(message: e) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if let s = store.summary {
                    overview(s)
                    wishlist(s)
                    Section {
                        ForEach([LedgerTable.income, .purchases, .investments]) { t in
                            NavigationLink {
                                LedgerTableView(store: store, table: t)
                            } label: {
                                Label(t.title, systemImage: t.systemImage)
                            }
                        }
                        NavigationLink {
                            ServerSpecsView(client: store.client)
                        } label: {
                            Label("Server specs", systemImage: "server.rack")
                        }
                        Button {
                            showShare = true
                        } label: {
                            LabeledContent {
                                Text(Format.percent(s.share))
                            } label: {
                                Label("Payback share", systemImage: "chart.pie")
                            }
                        }
                    }
                } else if store.error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Ledger")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(LedgerTable.allCases) { t in
                            Button {
                                editing = LedgerEdit(table: t, row: nil)
                            } label: {
                                Label("Add \(t.singular)", systemImage: t.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable { await store.refresh() }
            .polling(every: 60) { await store.refresh() }
            .sheet(item: $editing) { e in
                NavigationStack { LedgerRowForm(store: store, table: e.table, row: e.row) }
            }
            .sheet(item: $buying) { w in
                NavigationStack { LedgerBuyForm(store: store, wish: w) }
            }
            .sheet(isPresented: $showShare) {
                if let s = store.summary {
                    NavigationStack { LedgerShareForm(store: store, share: s.share) }
                        .presentationDetents([.medium])
                }
            }
        }
    }

    @ViewBuilder
    private func overview(_ s: LedgerSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Upgrade fund").font(.caption).foregroundStyle(.secondary)
                Text(Format.usd(s.fund))
                    .font(.largeTitle.weight(.bold).monospacedDigit())
                    .foregroundStyle(s.fund < 0 ? Color.red : Color.primary)
                Text("growing about \(Format.usd(s.fundRate))/day")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Payback")
                    Spacer()
                    Text("\(Format.usd(s.paid, cents: false)) of \(Format.usd(s.target, cents: false))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: min(s.paid, max(s.target, 0.01)), total: max(s.target, 0.01))
                    .tint(.green)
                Text(s.remaining <= 0 ? "Paid back. All income goes to the fund."
                     : "\(Format.usd(s.remaining)) left" + (s.paybackEta.map { " · around \(Format.day($0))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        Section {
            StatGrid {
                StatTile(title: "Mining (7-day avg)", value: s.rate7d.map { Format.usd($0) + "/day" } ?? "–",
                         detail: s.rateNow.map { "now \(Format.usd($0))/day" }, systemImage: "cpu", tint: .green)
                StatTile(title: "Since last payout", value: Format.usd(s.pendingEst),
                         detail: s.lastIncome.map { "last payout \(Format.day($0))" } ?? "no payouts yet",
                         systemImage: "hourglass")
                StatTile(title: "Income so far", value: Format.usd(s.incomeTotal, cents: false), systemImage: "arrow.down.circle")
                StatTile(title: "Spent from fund", value: Format.usd(s.spentFromFund, cents: false), systemImage: "cart")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private func wishlist(_ s: LedgerSummary) -> some View {
        Section {
            if s.wishlist.isEmpty {
                Text("Nothing on the wishlist.").foregroundStyle(.secondary)
            }
            ForEach(s.wishlist) { w in
                Button {
                    editing = LedgerEdit(table: .wishlist, row: LedgerRow(wish: w))
                } label: {
                    wishRow(w)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("Bought") { buying = w }.tint(.green)
                }
                .contextMenu {
                    Button { buying = w } label: { Label("Bought it", systemImage: "cart.badge.plus") }
                    if let link = w.link, let url = URL(string: link) {
                        Link(destination: url) { Label("Open link", systemImage: "safari") }
                    }
                    Button(role: .destructive) {
                        Task { await store.delete(.wishlist, id: w.id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Wishlist")
        } footer: {
            if !s.wishlist.isEmpty {
                Text("In priority order: each item counts what's above it. Swipe an item when you buy it.")
            }
        }
    }

    private func wishRow(_ w: LedgerSummary.WishItem) -> some View {
        HStack(spacing: 12) {
            LedgerThumb(client: store.client, image: w.image)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(w.item).lineLimit(2)
                    Spacer()
                    Text(Format.usd(w.estCost, cents: false)).font(.callout.monospacedDigit())
                }
                ProgressView(value: min(max(w.progress ?? 0, 0), 1))
                    .tint((w.need ?? 1) <= 0 ? Color.green : Color.accentColor)
                Text((w.need ?? 0) <= 0 ? "Affordable now"
                     : "\(Format.usd(w.need, cents: false)) to go" + (w.eta.map { " · around \(Format.day($0))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A sheet's subject: add (row == nil) or edit a row of a table.
struct LedgerEdit: Identifiable {
    let id = UUID()
    let table: LedgerTable
    let row: LedgerRow?
}

extension LedgerRow {
    init(wish w: LedgerSummary.WishItem) {
        self.init(id: w.id, date: nil, item: w.item, category: w.category, cost: nil, estCost: w.estCost,
                  fromFund: nil, outOfPocket: nil, amount: nil, currency: nil, usd: nil, priority: w.priority,
                  link: w.link, notes: w.notes, image: w.image, status: nil, statusDate: nil, soldPrice: nil)
    }
}

struct LedgerThumb: View {
    let client: APIClient
    let image: String?
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let image, !image.isEmpty {
                ServerImage(client: client, path: "img/\(image)", contentMode: .fit)
                    .background(Color.white)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
                    .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct LedgerTableView: View {
    let store: LedgerStore
    let table: LedgerTable
    @State private var editing: LedgerEdit?

    var body: some View {
        let rows = store.rows[table]
        List {
            if let rows {
                if rows.isEmpty {
                    Text("Nothing here yet.").foregroundStyle(.secondary)
                }
                ForEach(rows) { r in
                    Button {
                        editing = LedgerEdit(table: table, row: r)
                    } label: {
                        row(r)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { idx in
                    let ids = idx.map { rows[$0].id }
                    Task { for id in ids { await store.delete(table, id: id) } }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle(table.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = LedgerEdit(table: table, row: nil) } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await store.load(table) }
        .task { await store.load(table) }
        .sheet(item: $editing) { e in
            NavigationStack { LedgerRowForm(store: store, table: e.table, row: e.row) }
        }
    }

    private func row(_ r: LedgerRow) -> some View {
        HStack(spacing: 12) {
            if table != .income { LedgerThumb(client: store.client, image: r.image, size: 44) }
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(Format.day(r.date))
                    if let c = r.category, !c.isEmpty, table != .income { Text("· \(c)") }
                    if let st = r.status.flatMap(LedgerStatus.init(rawValue:)), st != .active {
                        Badge(text: st == .sold ? "sold \(Format.usd(r.soldPrice, cents: false))" : st.label, color: st.color)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if table == .income, let split = store.summary?.splits?[String(r.id)] {
                    Text("\(Format.usd(split.payback)) payback · \(Format.usd(split.fund)) fund")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if table == .purchases, let ff = r.fromFund {
                    Text("\(Format.usd(ff)) from fund · \(Format.usd(r.outOfPocket ?? 0)) out of pocket")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Format.usd(table == .income ? r.usd : r.cost)).font(.callout.monospacedDigit())
        }
        .contentShape(Rectangle())
    }
}
