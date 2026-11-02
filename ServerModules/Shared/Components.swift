import SwiftUI
import UIKit

/// Shows a module's content once its server URL is set, or a prompt to set it.
/// The content is rebuilt whenever the URL or login changes.
struct ModuleRoot<Content: View>: View {
    @Environment(ServerSettings.self) private var settings
    let kind: ServerKind
    @ViewBuilder let content: (APIClient) -> Content
    @State private var showSettings = false

    var body: some View {
        if let client = settings.client(kind) {
            content(client).id(client.identity)
        } else {
            ContentUnavailableView {
                Label("\(kind.title) isn't set up", systemImage: kind.systemImage)
            } description: {
                Text("Add the address of your \(kind.appName) server.")
            } actions: {
                Button("Set up \(kind.title)") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle(kind.title)
            .sheet(isPresented: $showSettings) {
                NavigationStack { ServerEditView(kind: kind) }
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Retry", action: retry).font(.callout.weight(.semibold))
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A small labelled number, used in the dashboards' grids.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var systemImage: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(tint) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            content
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

/// A row of a log, in a monospaced scrolling block.
struct LogView: View {
    let lines: [String]
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(lines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color(.secondarySystemBackground))
    }
}

/// An image fetched through the API client, so it carries the server's login header.
struct ServerImage: View {
    let client: APIClient
    let path: String
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
                    .overlay {
                        Image(systemName: failed ? "photo" : "ellipsis")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: path) {
            let key = "\(client.identity)|\(path)" as NSString
            if let hit = Self.cache.object(forKey: key) { image = hit; return }
            do {
                let data = try await client.data("GET", path)
                if let img = UIImage(data: data) {
                    Self.cache.setObject(img, forKey: key)
                    image = img
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }
}

extension View {
    /// Runs `action` now and then every `seconds` while the app is in the foreground and
    /// the view is on screen.
    func polling(every seconds: Double, _ action: @escaping () async -> Void) -> some View {
        modifier(PollingModifier(seconds: seconds, action: action))
    }
}

private struct PollingModifier: ViewModifier {
    @Environment(\.scenePhase) private var phase
    let seconds: Double
    let action: () async -> Void

    func body(content: Content) -> some View {
        content.task(id: phase == .active) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }
}
