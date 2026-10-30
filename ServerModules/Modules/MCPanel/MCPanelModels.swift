import SwiftUI

/// GET /api/servers
struct MCServers: Decodable {
    let servers: [MCServer]
    let updated: Double?
}

struct MCServer: Decodable, Identifiable {
    let name: String
    let config: MCConfig
    let status: MCStatus
    let busy: Bool
    let backups: [MCBackup]
    var id: String { name }
}

/// One entry of servers.yml.
struct MCConfig: Decodable {
    let type: String?
    let version: JSONValue?
    let jar: String?
    let java: String?
    let memory: JSONValue?
    let port: Int?
    let bedrockPort: Int?
    let autopause: Bool?
    let autostart: Bool?

    enum CodingKeys: String, CodingKey {
        case type, version, jar, java, memory, port, autopause, autostart
        case bedrockPort = "bedrock_port"
    }

    var typeLabel: String { MC.typeLabel(type ?? "") }

    var versionText: String {
        if type == "CUSTOM" { return jar ?? "custom jar" }
        return version?.string ?? "?"
    }
}

struct MCStatus: Decodable {
    /// running, starting, sleeping, stopped, missing or unknown
    let state: String
    let detail: String?
    let players: Int?
    let maxPlayers: Int?
    let runningVersion: String?
    let memory: String?
    let cpu: String?

    enum CodingKeys: String, CodingKey {
        case state, detail, players, memory, cpu
        case maxPlayers = "max_players"
        case runningVersion = "running_version"
    }

    var color: Color {
        switch state {
        case "running": return .green
        case "starting": return .yellow
        case "sleeping": return .blue
        case "stopped": return .gray
        case "missing": return .red
        default: return .secondary
        }
    }

    var label: String {
        switch state {
        case "sleeping": return "Sleeping (no players)"
        case "missing": return "Not created"
        default: return Format.capitalized(state)
        }
    }

    var isUp: Bool { ["running", "starting", "sleeping"].contains(state) }
}

struct MCBackup: Decodable, Identifiable, Hashable {
    let file: String
    let size: Double
    let time: Double
    var id: String { file }
}

/// A background task: start/stop, backup, restore, version change, add server…
struct MCJob: Decodable, Identifiable {
    let id: String
    let server: String
    let action: String
    /// running, done or failed
    let status: String
    let log: [String]
    let started: Double
    let ended: Double?

    var color: Color {
        switch status {
        case "running": return .blue
        case "done": return .green
        case "failed": return .red
        default: return .secondary
        }
    }
}

struct MCPanelConfig: Decodable {
    let forwardTo: String?
    let safetyDir: String?
    let importDir: String?

    enum CodingKeys: String, CodingKey {
        case forwardTo = "forward_to"
        case safetyDir = "safety_dir"
        case importDir = "import_dir"
    }
}

enum MC {
    static let types = ["VANILLA", "PAPER", "FABRIC", "FORGE", "NEOFORGE", "CUSTOM"]
    static let javas = ["java25", "java21", "java17", "java8"]
    static let difficulties = ["peaceful", "easy", "normal", "hard"]
    static let gamemodes = ["survival", "creative", "adventure", "spectator"]

    static func typeLabel(_ t: String) -> String {
        switch t {
        case "NEOFORGE": return "NeoForge"
        case "CUSTOM": return "Custom jar"
        default: return Format.capitalized(t.lowercased())
        }
    }

    static func javaLabel(_ j: String) -> String {
        switch j {
        case "java25": return "Java 25 (26.x)"
        case "java21": return "Java 21 (1.20.5 – 1.21.x)"
        case "java17": return "Java 17"
        case "java8": return "Java 8"
        default: return j
        }
    }
}
