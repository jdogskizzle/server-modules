import Foundation

struct APIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Talks JSON to one server. Paths are relative to the server's base URL, so a server
/// behind a reverse proxy under a sub-path (e.g. `https://home.example/musicflow`) works.
struct APIClient: Sendable {
    let baseURL: URL
    let headerName: String?
    let headerValue: String?
    /// Set for servers with a formlogin sign-in page: signs in and supplies the session cookie.
    var formSession: FormSession? = nil

    /// Changes whenever the URL or login changes, so views can rebuild their stores.
    var identity: String {
        "\(baseURL.absoluteString)|\(headerName ?? "")|\(headerValue?.hashValue ?? 0)|\(formSession?.fingerprint ?? "")"
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Session cookies are handled by FormSession, per server.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        var base = comps.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        comps.percentEncodedPath = base + "/" + rel
        comps.queryItems = query.isEmpty ? nil : query
        return comps.url ?? baseURL
    }

    /// Escapes one path segment (a name or id put into a URL path).
    static func segment(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let headerName, let headerValue, !headerName.isEmpty {
            req.setValue(headerValue, forHTTPHeaderField: headerName)
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        var cookie = try await formSession?.cookie(refreshing: nil)
        var (data, http) = try await Self.perform(req, cookie: cookie)
        if let formSession, Self.signedOut(http, request: req) {
            // The session expired or was revoked: sign in again and retry once.
            cookie = try await formSession.cookie(refreshing: cookie)
            (data, http) = try await Self.perform(req, cookie: cookie)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(Self.errorMessage(data, status: http.statusCode))
        }
        return data
    }

    private static func perform(_ request: URLRequest, cookie: String?) async throws -> (Data, HTTPURLResponse) {
        var req = request
        if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError(error.localizedDescription)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw APIError("No response from the server") }
        return (result.0, http)
    }

    /// formlogin refused the session: a 401 for API calls, or a redirect to the sign-in
    /// page for anything else (e.g. ledger's /img/ thumbnails).
    private static func signedOut(_ http: HTTPURLResponse, request: URLRequest) -> Bool {
        if http.statusCode == 401 { return true }
        return http.url?.lastPathComponent == "login" && request.url?.lastPathComponent != "login"
    }

    /// Session cookies for a web view showing this server (empty without a sign-in page).
    /// Call it after a request succeeded, so the session is known to be current.
    func webCookies() async throws -> [HTTPCookie] {
        guard let header = try await formSession?.cookie(refreshing: nil) else { return [] }
        return FormSession.webCookies(header, for: baseURL)
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        try Self.decode(T.self, from: await data("GET", path, query: query))
    }

    /// Sends a request and decodes the reply.
    func fetch<T: Decodable>(_ method: String, _ path: String, body: JSONValue = [:], as type: T.Type = T.self) async throws -> T {
        try Self.decode(T.self, from: await data(method, path, body: body))
    }

    /// Sends a request and ignores the reply (other than errors).
    func send(_ method: String, _ path: String, body: JSONValue = [:]) async throws {
        _ = try await data(method, path, body: body)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if data.first == UInt8(ascii: "<") {
                throw APIError("The server sent a web page instead of data. Check the URL, or whether a login page is in the way.")
            }
            switch error {
            case DecodingError.keyNotFound(let key, let ctx):
                throw APIError("Unexpected reply: \(describe(ctx.codingPath + [key])) is missing")
            case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
                throw APIError("Unexpected reply at \(describe(ctx.codingPath))")
            default:
                throw APIError("Unexpected reply from the server")
            }
        }
    }

    private static func describe(_ path: [CodingKey]) -> String {
        let s = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return s.isEmpty ? "the reply" : s
    }

    static func errorMessage(_ data: Data, status: Int) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let e = obj["error"] as? String { return e }
            if let d = obj["detail"] as? String {
                if d == "not signed in" {
                    return "This server has a sign-in page. In Settings, set its login to “Sign-in page” and enter your username and password."
                }
                return d
            }
            if let list = obj["detail"] as? [[String: Any]], let msg = list.first?["msg"] as? String { return msg }
        }
        if status == 401 || status == 403 {
            return "Not authorized (HTTP \(status)). Check the login in Settings."
        }
        return "HTTP \(status): " + HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }
}
