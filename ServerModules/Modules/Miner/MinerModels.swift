import Foundation

/// GET /api/status from the miner's control panel (control/control.py).
struct MinerStatus: Decodable {
    let now: Double
    let watchdog: Watchdog?
    let control: Control?
    let active: Active?
    let estimates: Estimates?
    let tuning: [String: Tuning]?
    let benchmark: Benchmark?
    let configPowerMode: String?
    let coins: [Coin]
    let configPin: String?
    let checkMinutes: Double?
    let live: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case now, watchdog, control, active, estimates, tuning, benchmark, coins, live
        case configPowerMode = "config_power_mode"
        case configPin = "config_pin"
        case checkMinutes = "check_minutes"
    }

    /// gpu-yield's state/status.json.
    struct Watchdog: Decodable {
        let state: String?
        let reason: String?
        let since: Double?
        let resumeAt: Double?
        enum CodingKeys: String, CodingKey {
            case state, reason, since
            case resumeAt = "resume_at"
        }
    }

    /// state/control.json: what the panel asked for.
    struct Control: Decodable {
        let paused: Bool?
        let pin: String?
        let powerMode: String?
        let checkRequested: Double?
        let benchmark: BenchmarkRequest?
        enum CodingKeys: String, CodingKey {
            case paused, pin, benchmark
            case powerMode = "power_mode"
            case checkRequested = "check_requested"
        }
    }

    struct BenchmarkRequest: Decodable {
        let coin: String
        let requested: Double
    }

    /// state/active.json: the coin being mined and its settings.
    struct Active: Decodable {
        let coin: String?
        let name: String?
        let algorithm: String?
        let powerMode: String?
        let tuned: Bool?
        let powerLimit: JSONValue?
        let coreClock: JSONValue?
        let memClock: JSONValue?
        let priceUsd: Double?
        let since: Double?
        enum CodingKeys: String, CodingKey {
            case coin, name, algorithm, tuned, since
            case powerMode = "power_mode"
            case powerLimit = "power_limit"
            case coreClock = "core_clock"
            case memClock = "mem_clock"
            case priceUsd = "price_usd"
        }
    }

    /// state/estimates.json, written by the switcher on every check.
    struct Estimates: Decodable {
        let updated: Double?
        let active: String?
        let btcUsd: Double?
        let powerMode: String?
        let nextCheck: Double?
        let coins: [String: CoinEstimate]?
        enum CodingKeys: String, CodingKey {
            case updated, active, coins
            case btcUsd = "btc_usd"
            case powerMode = "power_mode"
            case nextCheck = "next_check"
        }
    }

    struct CoinEstimate: Decodable {
        let name: String?
        let usdDay: Double?
        let liquid: Bool?
        let hashrate: Double?
        let hashrateSource: String?
        let priceUsd: Double?
        let modes: [String: ModeEstimate]?
        enum CodingKeys: String, CodingKey {
            case name, liquid, hashrate, modes
            case usdDay = "usd_day"
            case hashrateSource = "hashrate_source"
            case priceUsd = "price_usd"
        }
    }

    struct ModeEstimate: Decodable {
        let usdDay: Double?
        let hashrate: Double?
        let hashrateSource: String?
        let power: Double?
        let tuned: Bool?
        let coreClock: JSONValue?
        let memClock: JSONValue?
        enum CodingKeys: String, CodingKey {
            case hashrate, power, tuned
            case usdDay = "usd_day"
            case hashrateSource = "hashrate_source"
            case coreClock = "core_clock"
            case memClock = "mem_clock"
        }
    }

    /// state/tuning.json: one coin's benchmark result (or the error of a failed one).
    struct Tuning: Decodable {
        let benchmarked: Double?
        let error: String?
        let modes: [String: TunedMode]?
    }

    struct TunedMode: Decodable {
        let coreClock: JSONValue?
        let memClock: JSONValue?
        let hashrate: Double?
        let power: Double?
        enum CodingKeys: String, CodingKey {
            case hashrate, power
            case coreClock = "core_clock"
            case memClock = "mem_clock"
        }
    }

    /// state/benchmark.json: the benchmark running now, or the last one.
    struct Benchmark: Decodable {
        let coin: String?
        let name: String?
        let requested: JSONValue?
        let status: String?
        let message: String?
        let started: Double?
        let updated: Double?
        let step: Double?
        let steps: Double?
    }

    struct Coin: Decodable, Identifiable, Hashable {
        let key: String
        let name: String
        let algorithm: String
        var id: String { key }
    }
}

extension MinerStatus {
    static let modes = ["max", "efficient", "low"]

    static let modeInfo = [
        "max": "Highest hashrate",
        "efficient": "Most per watt, keeping 90%+ of max",
        "low": "Most per watt, keeping 70%+ of max",
    ]

    var currentMode: String {
        if let m = control?.powerMode, Self.modes.contains(m) { return m }
        return configPowerMode ?? "efficient"
    }

    var paused: Bool { control?.paused ?? false }
    var pin: String { control?.pin ?? "" }

    func coinName(_ key: String?) -> String {
        guard let key else { return "" }
        return coins.first { $0.key == key }?.name ?? key
    }

    func estimate(_ key: String?) -> CoinEstimate? {
        guard let key else { return nil }
        return estimates?.coins?[key]
    }

    /// The benchmark being run now, or one asked for that gpu-yield hasn't started yet.
    enum BenchState { case idle, queued(String), running(String) }

    var benchState: BenchState {
        let req = control?.benchmark
        let b = benchmark
        let started: Bool = {
            guard let req, let r = b?.requested?.double else { return false }
            return abs(r - req.requested) < 0.01
        }()
        if let req, !started { return .queued(req.coin) }
        if let b, b.status == "running", let coin = b.coin { return .running(coin) }
        return .idle
    }

    var benchBusy: Bool {
        if case .idle = benchState { return false }
        return true
    }

    func benchCoin() -> String? {
        switch benchState {
        case .idle: return nil
        case .queued(let c), .running(let c): return c
        }
    }

    /// Whether the miner is reporting hashes right now.
    var hashing: Bool {
        let s = watchdog?.state
        return (s == "mining" || s == "benchmarking") && (live?["miner_up"] ?? 0) > 0
    }
}
