import Foundation

enum Format {
    static func usd(_ v: Double?, cents: Bool = true) -> String {
        guard let v else { return "–" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = cents ? 2 : 0
        f.minimumFractionDigits = cents ? 2 : 0
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    /// Coin prices: whole dollars when large, a few significant digits when tiny.
    static func price(_ v: Double?) -> String {
        guard let v else { return "–" }
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 1 { return String(format: "$%.2f", v) }
        return "$" + String(format: "%.3g", v)
    }

    static func hashrate(_ hs: Double?, unit: String = "/s") -> String {
        guard var hs, hs > 0 else { return "–" }
        let units = ["H", "KH", "MH", "GH", "TH", "PH", "EH"]
        var i = 0
        while hs >= 1000 && i < units.count - 1 { hs /= 1000; i += 1 }
        let digits = hs < 10 ? 2 : hs < 100 ? 1 : 0
        return String(format: "%.\(digits)f", hs) + " " + units[i] + unit
    }

    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    static func ago(_ t: Double?, now: Double = Date().timeIntervalSince1970) -> String {
        guard let t, t > 0 else { return "–" }
        return duration(now - t) + " ago"
    }

    static func bytes(_ n: Double?) -> String {
        guard let n else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func percent(_ v: Double?, digits: Int = 0) -> String {
        guard let v else { return "–" }
        return String(format: "%.\(digits)f%%", v * 100)
    }

    static func number(_ v: Double?, digits: Int = 0) -> String {
        guard let v else { return "–" }
        return String(format: "%.\(digits)f", v)
    }

    /// "2026-10-30" → a medium date in the user's locale.
    static func day(_ iso: String?) -> String {
        guard let iso, let d = isoDay.date(from: String(iso.prefix(10))) else { return iso ?? "–" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func isoString(_ d: Date) -> String { isoDay.string(from: d) }

    static func time(_ t: Double?) -> String {
        guard let t else { return "–" }
        return Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)
    }

    static func capitalized(_ s: String?) -> String {
        guard let s, let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst()
    }
}
