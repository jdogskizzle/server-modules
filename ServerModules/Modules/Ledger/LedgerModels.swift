import SwiftUI

/// GET /api/summary
struct LedgerSummary: Decodable {
    let share: Double
    let target: Double
    let paid: Double
    let remaining: Double
    let fund: Double
    let incomeTotal: Double
    let investedTotal: Double
    let spentFromFund: Double
    let lastIncome: String?
    let soldTotal: Double?
    let rate7d: Double?
    let rateNow: Double?
    let pendingEst: Double?
    let rate: Double
    let fundRate: Double
    let paybackEta: String?
    let wishlist: [WishItem]
    let splits: [String: Split]?
    let hardware: [String: [String: Double]]?

    enum CodingKeys: String, CodingKey {
        case share, target, paid, remaining, fund, rate, wishlist, splits, hardware
        case incomeTotal = "income_total"
        case investedTotal = "invested_total"
        case spentFromFund = "spent_from_fund"
        case lastIncome = "last_income"
        case soldTotal = "sold_total"
        case rate7d = "rate_7d"
        case rateNow = "rate_now"
        case pendingEst = "pending_est"
        case fundRate = "fund_rate"
        case paybackEta = "payback_eta"
    }

    struct Split: Decodable {
        let payback: Double
        let fund: Double
    }

    /// A wishlist row plus how close the fund is to it (in priority order).
    struct WishItem: Decodable, Identifiable {
        let id: Int
        let item: String
        let category: String?
        let estCost: Double?
        let priority: Int?
        let link: String?
        let notes: String?
        let image: String?
        let need: Double?
        let progress: Double?
        let eta: String?

        enum CodingKeys: String, CodingKey {
            case id, item, category, priority, link, notes, image, need, progress, eta
            case estCost = "est_cost"
        }
    }
}

/// The four editable tables (`/api/{table}`).
enum LedgerTable: String, CaseIterable, Identifiable {
    case income, purchases, investments, wishlist
    var id: String { rawValue }

    var title: String {
        switch self {
        case .income: return "Payouts"
        case .purchases: return "Purchases"
        case .investments: return "Already spent"
        case .wishlist: return "Wishlist"
        }
    }

    var singular: String {
        switch self {
        case .income: return "payout"
        case .purchases: return "purchase"
        case .investments: return "item"
        case .wishlist: return "wish"
        }
    }

    var systemImage: String {
        switch self {
        case .income: return "arrow.down.circle"
        case .purchases: return "cart"
        case .investments: return "shippingbox"
        case .wishlist: return "star"
        }
    }
}

/// One row of any table. Every field is optional; which ones exist depends on the table.
struct LedgerRow: Decodable, Identifiable, Hashable {
    let id: Int
    let date: String?
    let item: String?
    let category: String?
    let cost: Double?
    let estCost: Double?
    let fromFund: Double?
    let outOfPocket: Double?
    let amount: Double?
    let currency: String?
    let usd: Double?
    let priority: Int?
    let link: String?
    let notes: String?
    let image: String?
    let status: String?
    let statusDate: String?
    let soldPrice: Double?

    enum CodingKeys: String, CodingKey {
        case id, date, item, category, cost, amount, currency, usd, priority, link, notes, image, status
        case estCost = "est_cost"
        case fromFund = "from_fund"
        case outOfPocket = "out_of_pocket"
        case statusDate = "status_date"
        case soldPrice = "sold_price"
    }

    var title: String { item ?? (amount.map { "\(Format.number($0, digits: 8)) \(currency ?? "BTC")" } ?? "Payout") }
}

enum LedgerStatus: String, CaseIterable, Identifiable {
    case active, idle, broken, sold
    var id: String { rawValue }
    var label: String {
        switch self {
        case .active: return "In use"
        case .idle: return "Not in use"
        case .broken: return "Broken"
        case .sold: return "Sold"
        }
    }
    var color: Color {
        switch self {
        case .active: return .green
        case .idle: return .gray
        case .broken: return .red
        case .sold: return .blue
        }
    }
}

/// GET /api/server/specs
struct ServerSpecs: Decodable {
    struct CPU: Decodable {
        let model: String?
        let cores: Int?
        let threads: Int?
        let maxGhz: Double?
        enum CodingKeys: String, CodingKey {
            case model, cores, threads
            case maxGhz = "max_ghz"
        }
    }
    struct Memory: Decodable {
        let installedGb: Double?
        let usableGib: Double?
        enum CodingKeys: String, CodingKey {
            case installedGb = "installed_gb"
            case usableGib = "usable_gib"
        }
    }
    struct Device: Decodable, Hashable {
        let vendor: String?
        let name: String?
        let vram: String?
        let integrated: Bool?
        let link: String?
        let wifi: Bool?
    }
    struct Mount: Decodable, Hashable {
        let mount: String
        let size: Double?
        let avail: Double?
    }
    struct Disk: Decodable, Hashable {
        let name: String
        let model: String?
        let size: String?
        let type: String?
        let array: String?
        let mounts: [Mount]?
    }
    struct RaidArray: Decodable, Hashable {
        let name: String
        let level: String?
        let size: String?
        let disks: [String]?
        let healthy: Bool?
        let mounts: [Mount]?
    }
    struct Storage: Decodable {
        let disks: [Disk]
        let arrays: [RaidArray]
    }
    struct Board: Decodable {
        let vendor: String?
        let name: String?
        let bios: String?
    }
    struct System: Decodable {
        let os: String?
        let kernel: String?
        let uptimeDays: Double?
        enum CodingKeys: String, CodingKey {
            case os, kernel
            case uptimeDays = "uptime_days"
        }
    }

    let cpu: CPU?
    let memory: Memory?
    let gpus: [Device]?
    let network: [Device]?
    let storage: Storage?
    let board: Board?
    let system: System?
}
