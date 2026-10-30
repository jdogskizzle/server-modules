import SwiftUI

/// GET /api/overview
struct MFOverview: Decodable {
    let artists: [MFArtistSummary]
    let activeJobs: Int
    let worker: MFWorker?
    let format: String
    let formats: [String: String]
    let jellyfin: Bool?
    let slskd: Bool?

    enum CodingKeys: String, CodingKey {
        case artists, worker, format, formats, jellyfin, slskd
        case activeJobs = "active_jobs"
    }
}

struct MFArtistSummary: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let monitored: Bool?
    let total: Int
    let have: Int
    let missing: Int
    let partial: Int
    let active: Int
}

struct MFWorker: Decodable {
    let running: Bool
    let note: String?
}

/// GET /api/artist/{id}
struct MFArtist: Decodable {
    let id: Int
    let name: String
    let path: String?
    let albums: [MFAlbum]
}

struct MFAlbum: Decodable, Identifiable {
    let id: Int
    let title: String
    let year: String?
    let type: String?
    let secondary: [String]?
    let monitored: Bool
    /// have, missing, partial, active or unreleased
    let status: String
    let have: Int
    let total: Int
    let want: String?
    let selected: String?
    let job: MFJob?
    let search: MFSearch?
    let date: String?
    let dateSrc: String?

    enum CodingKeys: String, CodingKey {
        case id, title, year, type, secondary, monitored, status, have, total, want, selected, job, search, date
        case dateSrc = "date_src"
    }

    var kindLabel: String {
        ([type].compactMap { $0 } + (secondary ?? [])).joined(separator: " · ")
    }
}

struct MFSearch: Decodable {
    /// queued, searching, loading, done or error
    let state: String
    let text: String?
    let release: String?
    let error: String?
    let at: Double?
    let candidates: [MFCandidate]?
    let total: Int?

    var running: Bool { ["queued", "searching", "loading"].contains(state) }
}

struct MFCandidate: Decodable, Identifiable, Hashable {
    let formatOk: Bool?
    let score: Int
    let username: String
    let dir: String
    let folder: String
    let count: Int
    let ext: String
    let quality: String
    let size: Double?
    let free: Bool?
    let speed: Double?
    let queue: Double?
    let multidisc: Bool?
    let failed: Bool?
    let files: [String]

    var id: String { username + "\u{1}" + dir }

    enum CodingKeys: String, CodingKey {
        case score, username, dir, folder, count, ext, quality, size, free, speed, queue, multidisc, failed, files
        case formatOk = "format_ok"
    }
}

/// A queued or finished job (GET /api/jobs, and on each album).
struct MFJob: Decodable, Identifiable {
    let id: String
    /// download, import or finish
    let kind: String
    /// picked, queued, downloaded, pending, processing, done or failed
    let status: String
    let artist: String?
    let album: String?
    let artistId: Int?
    let albumId: Int?
    let username: String?
    let error: String?
    let log: [String]?
    let reports: [[String: JSONValue]]?
    let pct: Double?
    let speed: Double?
    let state: String?
    let fileCount: Int?
    let size: Double?
    let created: Double?
    let finishedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, kind, status, artist, album, username, error, log, reports, pct, speed, state, size, created
        case artistId = "artist_id"
        case albumId = "album_id"
        case fileCount = "file_count"
        case finishedAt = "finished_at"
    }

    static let activeStatuses: Set<String> = ["picked", "queued", "downloaded", "pending", "processing"]
    var isActive: Bool { Self.activeStatuses.contains(status) }
    var canRetry: Bool { status == "failed" }
    var canCancel: Bool { ["picked", "queued", "pending"].contains(status) }
    var canDismiss: Bool { !["queued", "processing"].contains(status) }

    var kindLabel: String {
        switch kind {
        case "download": return "Download"
        case "import": return "Import"
        case "finish": return "Redo"
        default: return kind
        }
    }

    var statusText: String {
        if status == "queued" {
            if let s = state, s.hasPrefix("Queued") { return "Waiting in \(username ?? "their")'s queue" }
            return "Downloading \(Int((pct ?? 0).rounded()))%"
        }
        return MF.statusLabel(status)
    }
}

struct MFJobs: Decodable {
    let jobs: [MFJob]
    let worker: MFWorker?
}

struct MFDisk: Decodable {
    struct Drive: Decodable, Identifiable {
        let label: String
        let total: Double
        let free: Double
        var id: String { label }
    }
    let drives: [Drive]
}

struct MFFolders: Decodable {
    struct Folder: Decodable, Identifiable, Hashable {
        let path: String
        let name: String
        let files: Int
        let mtime: Double
        var id: String { path }
    }
    let folders: [Folder]
}

struct MFImportGuess: Decodable {
    struct Album: Decodable, Identifiable, Hashable {
        let id: Int
        let title: String
        let year: String?
    }
    let guess: Int?
    let albums: [Album]
    let files: Int
}

struct MFSettings: Decodable {
    let format: String
    let formats: [String: String]
}

enum MF {
    static func statusLabel(_ s: String) -> String {
        [
            "have": "Have", "missing": "Missing", "partial": "Partial", "active": "In progress",
            "unreleased": "Unreleased", "picked": "Waiting", "queued": "Downloading",
            "downloaded": "Downloaded", "pending": "Waiting", "processing": "Finishing",
            "done": "Done", "failed": "Failed",
        ][s] ?? Format.capitalized(s)
    }

    static func statusColor(_ s: String) -> Color {
        switch s {
        case "have", "done": return .green
        case "missing", "failed": return .red
        case "partial": return .orange
        case "active", "queued", "processing", "picked", "pending", "downloaded": return .blue
        default: return .secondary
        }
    }

    static func speed(_ n: Double?) -> String {
        guard let n, n > 0 else { return "" }
        return String(format: "%.1f MB/s", n / 1e6)
    }

    /// The format options in the order the web app lists them.
    static let formatOrder = ["cd", "hires", "any"]
}
