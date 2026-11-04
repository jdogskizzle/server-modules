import Foundation
import Observation

/// The server apps this client knows. The order is the order on the Home page.
enum ServerKind: String, CaseIterable, Identifiable, Codable {
    case musicflow, dvr, admute, miner, ledger, mcpanel, grafana

    var id: String { rawValue }

    private var info: (title: String, appName: String, systemImage: String, urlHint: String,
                       setupNote: String, probePath: String, group: String) {
        switch self {
        case .musicflow:
            return ("Music", "musicflow", "music.note.list", "https://homeserver/musicflow",
                    "musicflow-web, directly on port 8000 or behind your proxy at /musicflow.",
                    "api/settings", "Media")
        case .dvr:
            return ("DVR", "dvr-guard", "record.circle", "https://homeserver/dvr",
                    "dvr-guard's status page, behind your proxy (e.g. /dvr).", "api/status", "Media")
        case .admute:
            return ("TV ad mute", "admute studio", "speaker.slash", "https://homeserver/admute",
                    "admute's studio, behind your proxy (e.g. /admute).", "api/live", "Media")
        case .miner:
            return ("Miner", "GPU miner control", "cpu", "http://homeserver:8095",
                    "The miner's control panel (CONTROL_PORT, 8095 by default).", "api/status", "Server")
        case .ledger:
            return ("Ledger", "Server fund ledger", "banknote", "http://homeserver:8000",
                    "The ledger web UI (PORT, 8000 by default), or its proxy sub-path.", "api/summary", "Server")
        case .mcpanel:
            return ("Minecraft", "mcpanel", "cube", "https://homeserver/mcpanel",
                    "mcpanel has no published port: use the address of your reverse proxy.", "api/config", "Games")
        case .grafana:
            return ("Dashboards", "Grafana", "chart.xyaxis.line", "http://homeserver:3000",
                    "Grafana (port 3000 by default), or its proxy sub-path. Sign in with a Grafana user; a viewer is enough.",
                    "api/search", "Server")
        }
    }

    var title: String { info.title }
    var appName: String { info.appName }
    var systemImage: String { info.systemImage }
    var urlHint: String { info.urlHint }
    var setupNote: String { info.setupNote }
    /// A cheap GET that proves the URL and login work.
    var probePath: String { info.probePath }
    /// The Home page section it's listed under.
    var group: String { info.group }

    static let groups = ["Media", "Server", "Games"]

    /// How "Sign-in page" signs in to this server.
    var loginStyle: FormSession.Style { self == .grafana ? .grafana : .formlogin }
}

enum AuthMode: String, Codable, CaseIterable, Identifiable {
    case noLogin = "none", form, basic, bearer, header
    var id: String { rawValue }
    var label: String {
        switch self {
        case .noLogin: return "None"
        case .form: return "Sign-in page"
        case .basic: return "Proxy username & password"
        case .bearer: return "Bearer token"
        case .header: return "Custom header"
        }
    }
}

struct ServerConfig: Codable, Equatable {
    var enabled = true
    var baseURL = ""
    var auth: AuthMode = .form
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

    /// Services shown as tabs between Home and Settings: three slots, each empty or a service.
    private(set) var tabSlots: [ServerKind?]
    static let tabSlotCount = 3
    private static let tabsKey = "tabSlots.v1"

    /// One sign-in session per server, shared by every client made for it, so screens
    /// don't each sign in. Replaced when the URL or login changes.
    @ObservationIgnored private var formSessions: [ServerKind: FormSession] = [:]

    init() {
        var loaded: [ServerKind: ServerConfig] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: ServerConfig].self, from: data) {
            for (k, v) in saved { if let kind = ServerKind(rawValue: k) { loaded[kind] = v } }
        }
        for kind in ServerKind.allCases where loaded[kind] == nil { loaded[kind] = ServerConfig() }
        configs = loaded
        let saved = UserDefaults.standard.stringArray(forKey: Self.tabsKey) ?? []
        tabSlots = (0..<Self.tabSlotCount).map { i in i < saved.count ? ServerKind(rawValue: saved[i]) : nil }
    }

    func config(_ kind: ServerKind) -> ServerConfig { configs[kind] ?? ServerConfig() }

    func secret(_ kind: ServerKind) -> String { Keychain.read("secret.\(kind.rawValue)") ?? "" }

    /// The pinned services, in tab order.
    var pinnedTabs: [ServerKind] { tabSlots.compactMap { $0 } }

    /// Puts a service in a tab slot (nil empties it). A service already in another slot
    /// moves here, so each one has at most one tab.
    func setTab(_ slot: Int, _ kind: ServerKind?) {
        guard tabSlots.indices.contains(slot) else { return }
        var slots = tabSlots
        if let kind {
            for i in slots.indices where slots[i] == kind { slots[i] = nil }
        }
        slots[slot] = kind
        tabSlots = slots
        UserDefaults.standard.set(slots.map { $0?.rawValue ?? "" }, forKey: Self.tabsKey)
    }

    func save(_ kind: ServerKind, config: ServerConfig, secret: String) {
        var c = config
        c.baseURL = c.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        configs[kind] = c
        Keychain.write(c.auth == .noLogin ? nil : secret, for: "secret.\(kind.rawValue)")
        // Sign in afresh with the saved login.
        Keychain.write(nil, for: Self.sessionKey(kind))
        formSessions[kind] = nil
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
        let c = config(kind)
        let password = secret(kind)
        return Self.makeClient(c, secret: password, style: kind.loginStyle) { loginURL in
            let fp = FormSession.fingerprint(loginURL: loginURL, username: c.username, password: password)
            if let existing = self.formSessions[kind], existing.fingerprint == fp { return existing }
            let session = FormSession(loginURL: loginURL, username: c.username, password: password,
                                      storageKey: Self.sessionKey(kind), style: kind.loginStyle)
            self.formSessions[kind] = session
            return session
        }
    }

    private static func sessionKey(_ kind: ServerKind) -> String { "session.\(kind.rawValue)" }

    /// `formSession` supplies the sign-in session for the server's login URL; by default a
    /// fresh one that isn't saved (as "Test connection" wants).
    static func makeClient(_ c: ServerConfig, secret: String, style: FormSession.Style = .formlogin,
                           formSession: ((URL) -> FormSession)? = nil) -> APIClient? {
        var text = c.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        switch c.auth {
        case .noLogin:
            return APIClient(baseURL: url, headerName: nil, headerValue: nil)
        case .form:
            var client = APIClient(baseURL: url, headerName: nil, headerValue: nil)
            let loginURL = client.url("login")
            client.formSession = formSession?(loginURL)
                ?? FormSession(loginURL: loginURL, username: c.username, password: secret, storageKey: nil, style: style)
            return client
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
