import Foundation
import KosmosIPC
import UserNotifications

/// `kosmos notify <title> <body>`: a notification from Kosmos. Its alert style in System
/// Settings decides whether it stays on screen (docs/ipc.md).
@MainActor
func notify(title: String, body: String) async -> Response {
    let center = UNUserNotificationCenter.current()
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined:
        // The prompt waits for the user, past the CLI's 5 s, so this one is not sent; the
        // sender tries again once the user allows it.
        Task { _ = try? await center.requestAuthorization(options: [.alert]) }
        return Response(exitCode: 1, stderr: "kosmos: macOS is asking whether Kosmos may notify; allow it, then send again")
    case .denied:
        return Response(exitCode: 1, stderr: "kosmos: notifications from Kosmos are off in System Settings > Notifications")
    default:
        break
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    do {
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        return Response()
    } catch {
        return Response(exitCode: 1, stderr: "kosmos: " + error.localizedDescription)
    }
}
