import SwiftUI
import UIKit
import UserNotifications

/// Push notifications from the notifier server (Grafana alerts sent through APNs).
///
/// Turning notifications on asks iOS for permission, registers for remote notifications and
/// sends the device token to notifier (`POST api/devices`), again on every launch, as APNs
/// tokens can change. Turning them off removes the device there. Tapping a notification
/// sets `openAlertID`, which the app shows.
@MainActor @Observable
final class PushManager {
    static let shared = PushManager()

    /// Notifications are on for this iPhone (kept across launches).
    private(set) var enabled = UserDefaults.standard.bool(forKey: PushManager.enabledKey)
    /// The APNs device token, lowercase hex, once iOS has given one.
    private(set) var token: String?
    /// Whether notifier has this device, and when it was last told.
    private(set) var registeredAt: Date?
    /// Whether notifier can send pushes at all ("on", or "off" until its APNs key is installed).
    private(set) var serverPush: String?
    var error: String?
    /// The alert to show, after a notification was tapped.
    var openAlertID: Int?

    /// Where the notifier server's address and login come from.
    @ObservationIgnored weak var settings: ServerSettings?

    private static let enabledKey = "notifier.push.enabled"

    /// Debug builds from Xcode get sandbox tokens; TestFlight and App Store builds production ones.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private var client: APIClient? { settings?.client(.notifier) }

    /// At launch: if notifications are on, register again so notifier has the current token.
    func launch() {
        if enabled { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Asks for permission, then registers. Returns whether notifications are now on.
    @discardableResult
    func enable() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                error = "Notifications are off for this app. Turn them on in iOS Settings → Notifications → Server Modules."
                return false
            }
        } catch {
            self.error = error.localizedDescription
            return false
        }
        setEnabled(true)
        error = nil
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    /// Stops pushes to this iPhone: removes the device from notifier.
    func disable() async {
        setEnabled(false)
        registeredAt = nil
        guard let token, let client else { return }
        do {
            try await client.send("DELETE", "api/devices/\(token)")
            error = nil
        } catch {
            self.error = "Couldn't remove this iPhone from notifier: \(error.localizedDescription)"
        }
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
    }

    // MARK: From the app delegate

    func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await upload() }
    }

    func didFailToRegister(_ e: Error) {
        error = "iOS couldn't register for notifications: \(e.localizedDescription)"
    }

    // MARK: notifier

    /// Sends this device's token to notifier (when notifications are on and it's set up).
    func upload() async {
        guard enabled, let token else { return }
        guard let client else {
            error = "Set up Alerts (notifier) in Settings to get notifications."
            return
        }
        struct Reply: Decodable { let push: String? }
        do {
            let reply: Reply = try await client.fetch("POST", "api/devices", body: [
                "token": .string(token), "environment": .string(Self.environment),
                "name": .string(UIDevice.current.name),
            ])
            serverPush = reply.push
            registeredAt = Date()
            error = nil
        } catch {
            self.error = "Couldn't register this iPhone with notifier: \(error.localizedDescription)"
        }
    }
}

/// Receives the APNs token and notification taps for the SwiftUI app.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushManager.shared.didFailToRegister(error) }
    }

    /// Show alerts that arrive while the app is open, too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Tapping a notification opens its alert (the payload's alert_id; the test push has none).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info["alert_id"] as? NSNumber)?.intValue ?? (info["alert_id"] as? String).flatMap { Int($0) }
        Task { @MainActor in
            if let id { PushManager.shared.openAlertID = id }
            completionHandler()
        }
    }
}
