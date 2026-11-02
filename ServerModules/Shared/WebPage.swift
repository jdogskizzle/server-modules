import SwiftUI
import WebKit

/// A web page of one of the servers, signed in with the app's session cookies.
struct ServiceWebView: UIViewRepresentable {
    let url: URL
    let cookies: [HTTPCookie]
    let reload: Int
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        context.coordinator.load(url, cookies: cookies, reload: reload, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.loading = $loading
        if context.coordinator.loadedURL != url {
            context.coordinator.load(url, cookies: cookies, reload: reload, in: view)
        } else if context.coordinator.reload != reload {
            context.coordinator.reload = reload
            view.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loading: Binding<Bool>
        var loadedURL: URL?
        var reload = 0

        init(loading: Binding<Bool>) { self.loading = loading }

        func load(_ url: URL, cookies: [HTTPCookie], reload: Int, in view: WKWebView) {
            loadedURL = url
            self.reload = reload
            let store = view.configuration.websiteDataStore.httpCookieStore
            Task { @MainActor in
                for c in cookies { await store.setCookie(c) }
                view.load(URLRequest(url: url))
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loading.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loading.wrappedValue = false
        }
    }
}


/// A server's own web page inside the app, for what the app doesn't do natively.
struct ServiceWebPage: View {
    let client: APIClient
    let title: String
    /// Path of the page, relative to the server's address ("" for its home page).
    var path = ""
    /// An API call that needs a session, made first so the session is current.
    let probePath: String
    @State private var cookies: [HTTPCookie]?
    @State private var error: String?
    @State private var reload = 0
    @State private var loading = true

    var body: some View {
        Group {
            if let cookies {
                ServiceWebView(url: client.url(path), cookies: cookies, reload: reload, loading: $loading)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        if loading { ProgressView().padding(.top, 8) }
                    }
            } else if let error {
                ContentUnavailableView {
                    Label("Can't open the page", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await signIn() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Link(destination: client.url(path)) { Image(systemName: "safari") }
                Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { await signIn() }
    }

    private func signIn() async {
        error = nil
        do {
            _ = try await client.data("GET", probePath)
            cookies = try await client.webCookies()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
