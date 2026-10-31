import CryptoKit
import Foundation

/// Signs in to a server that uses formlogin (github.com/jdogskizzle/formlogin) and keeps
/// its session cookie.
///
/// formlogin answers `POST <app>/login` (form fields `username`, `password`) with a 303
/// and a `<app>_session` cookie that lasts 30 days, a 401 page for a wrong password, and
/// a 429 page when an address has failed too often (5 times in 15 minutes). API calls
/// without a valid session get `401 {"detail": "not signed in"}`.
///
/// The cookie is kept in the Keychain so the app stays signed in across launches. After a
/// wrong password it stops trying until the login is changed in Settings, so polling
/// screens can't lock the account out.
actor FormSession {
    let loginURL: URL
    let username: String
    let password: String
    /// Keychain account the cookie is saved under (nil: don't save, e.g. for "Test connection").
    let storageKey: String?
    /// Changes with the URL, username or password; a saved cookie only counts if it matches.
    let fingerprint: String

    private var cookie: String?
    private var signInTask: Task<String?, Error>?
    private var failure: (error: APIError, until: Date)?
    /// The server answered /login with "not found": it has no sign-in (formlogin turned off).
    private var noSignIn = false

    init(loginURL: URL, username: String, password: String, storageKey: String?) {
        self.loginURL = loginURL
        self.username = username
        self.password = password
        self.storageKey = storageKey
        let fp = Self.fingerprint(loginURL: loginURL, username: username, password: password)
        self.fingerprint = fp
        if let storageKey, let saved = Keychain.read(storageKey) {
            let parts = saved.split(separator: "\n", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == fp { cookie = parts[1] }
        }
    }

    static func fingerprint(loginURL: URL, username: String, password: String) -> String {
        let digest = SHA256.hash(data: Data("\(loginURL.absoluteString)\u{0}\(username)\u{0}\(password)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The cookie to send, signing in first if there is none, or if `stale` (the one a
    /// request was just refused with) is still the current one. nil when the server has
    /// no sign-in.
    func cookie(refreshing stale: String?) async throws -> String? {
        if noSignIn { return nil }
        if let c = cookie, c != stale { return c }
        if let f = failure, f.until > Date() { throw f.error }
        if let running = signInTask { return try await running.value }
        let task = Task { try await self.signIn() }
        signInTask = task
        defer { signInTask = nil }
        return try await task.value
    }

    private func signIn() async throws -> String? {
        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("username=\(Self.formEncode(username))&password=\(Self.formEncode(password))".utf8)

        let result: (Data, URLResponse)
        do {
            // Don't follow the 303: its Set-Cookie header is what we're after.
            result = try await APIClient.session.data(for: req, delegate: NoRedirect.shared)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError("Can't reach the sign-in page: \(error.localizedDescription)")
        }
        let (body, response) = result
        guard let http = response as? HTTPURLResponse else { throw APIError("No response from the sign-in page") }

        switch http.statusCode {
        case 300..<400:
            guard let c = Self.sessionCookie(http) else {
                throw APIError("The server didn't send a session after signing in. Check the address in Settings.")
            }
            cookie = c
            failure = nil
            if let storageKey { Keychain.write(fingerprint + "\n" + c, for: storageKey) }
            return c
        case 401:
            // Don't try again with the same password; the server locks out after 5 failures.
            let e = APIError("Wrong username or password. Fix the login in Settings.")
            failure = (e, .distantFuture)
            throw e
        case 429:
            let text = String(decoding: body, as: UTF8.self)
            let minutes = text.range(of: #"in (\d+) min"#, options: .regularExpression)
                .flatMap { Int(text[$0].filter(\.isNumber)) } ?? 15
            let e = APIError("Too many failed sign-ins. The server will let you try again in \(minutes) min.")
            failure = (e, Date().addingTimeInterval(Double(minutes) * 60))
            throw e
        case 404, 405:
            noSignIn = true
            return nil
        default:
            throw APIError("Sign-in failed: " + APIClient.errorMessage(body, status: http.statusCode))
        }
    }

    /// "ledger_session=<value>" from the Set-Cookie header (empty values are sign-outs).
    static func sessionCookie(_ http: HTTPURLResponse) -> String? {
        guard let raw = http.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        let pair = raw.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return pair
    }

    /// application/x-www-form-urlencoded: letters, digits and -._~ as-is, the rest %-escaped.
    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.unicodeScalars.map { u -> String in
            if u.isASCII, allowed.contains(u) { return String(u) }
            return String(u).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }
}

/// Stops URLSession following a redirect, so the redirect response itself comes back.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
