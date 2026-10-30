import Foundation
import Observation

/// The four server apps this client knows.
enum ServerKind: String, CaseIterable, Identifiable, Codable {
    case miner, musicflow, mcpanel, ledger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .miner: return "Miner"
        case .musicflow: return "Music"
        case .mcpanel: return "Minecraft"
        case .ledger: return "Ledger"
        }
    }

    var appName: String {
        switch self {
        case .miner: return "GPU miner control"
        case .musicflow: return "musicflow"
        case .mcpanel: return "mcpanel"
        case .ledger: return "Server fund ledger"
        }
    }

    var systemImage: String {
        switch self {
        case .miner: return "cpu"
        case .musicflow: return "music.note.list"
        case .mcpanel: return "cube"
        case .ledger: return "banknote"
        }
    }

    var urlHint: String {
        switch self {
        case .miner: return "http://homeserver:8095"
        case .musicflow: return "https://homeserver/musicflow"
        case .mcpanel: return "https://homeserver/mcpanel"
        case .ledger: return "http://homeserver:8000"
        }
    }

    var setupNote: String {
        switch self {
        case .miner: return "The miner's control panel (CONTROL_PORT, 8095 by default)."
        case .musicflow: return "musicflow-web, directly on port 8000 or behind your proxy at /musicflow."
        case .mcpanel: return "mcpanel has no published port: use the address of your reverse proxy, with its login below."
        case .ledger: return "The ledger web UI (PORT, 8000 by default), or its proxy sub-path."
        }
    }

    /// A cheap GET that proves the URL and login work.
    var probePath: String {
        switch self {
        case .miner: return "api/status"
        case .musicflow: return "api/settings"
        case .mcpanel: return "api/config"
        case .ledger: return "api/summary"
        }
    }
}

enum AuthMode: String, Codable, CaseIterable, Identifiable {
    case noLogin = "none", basic, bearer, header
    var id: String { rawValue }
    var label: String {
        switch self {
        case .noLogin: return "None"
        case .basic: return "Username & password"
        case .bearer: return "Bearer token"
        case .header: return "Custom header"
        }
    }
}

struct ServerConfig: Codable, Equatable {
    var enabled = true
    var baseURL = ""
    var auth: AuthMode = .noLogin
    var username = ""
    var headerName = ""
}

/// Every server's URL and login. URLs live in UserDefaults; passwords and tokens in the Keychain.
@Observable
final class ServerSettings {
    private(set) var configs: [ServerKind: ServerConfig]
    /// Bumped on every change so views rebuild their clients.
    private(set) var revision = 0

    private static let defaultsKey = "serverConfigs.v1"

    init() {
        var loaded: [ServerKind: ServerConfig] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: ServerConfig].self, from: data) {
            for (k, v) in saved { if let kind = ServerKind(rawValue: k) { loaded[kind] = v } }
        }
        for kind in ServerKind.allCases where loaded[kind] == nil { loaded[kind] = ServerConfig() }
        configs = loaded
    }

    func config(_ kind: ServerKind) -> ServerConfig { configs[kind] ?? ServerConfig() }

    func secret(_ kind: ServerKind) -> String { Keychain.read("secret.\(kind.rawValue)") ?? "" }

    func save(_ kind: ServerKind, config: ServerConfig, secret: String) {
        var c = config
        c.baseURL = c.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        configs[kind] = c
        Keychain.write(c.auth == .noLogin ? nil : secret, for: "secret.\(kind.rawValue)")
        let raw = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        revision += 1
    }

    var enabledKinds: [ServerKind] { ServerKind.allCases.filter { config($0).enabled } }

    /// A client for the server, or nil while its URL isn't set.
    func client(_ kind: ServerKind) -> APIClient? {
        _ = revision
        return Self.makeClient(config(kind), secret: secret(kind))
    }

    static func makeClient(_ c: ServerConfig, secret: String) -> APIClient? {
        var text = c.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        switch c.auth {
        case .noLogin:
            return APIClient(baseURL: url, headerName: nil, headerValue: nil)
        case .basic:
            let token = Data("\(c.username):\(secret)".utf8).base64EncodedString()
            return APIClient(baseURL: url, headerName: "Authorization", headerValue: "Basic \(token)")
        case .bearer:
            return APIClient(baseURL: url, headerName: "Authorization", headerValue: "Bearer \(secret)")
        case .header:
            let name = c.headerName.trimmingCharacters(in: .whitespaces)
            return APIClient(baseURL: url, headerName: name.isEmpty ? nil : name, headerValue: secret)
        }
    }
}
