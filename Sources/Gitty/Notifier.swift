import AppKit
import UserNotifications

/// 오래 걸린 작업이 끝났을 때, 다른 앱을 쓰고 있으면 macOS 알림으로 알려 준다.
@MainActor
enum Notifier {
    /// 이보다 오래 걸린 작업만 알린다
    static let minimumSeconds: TimeInterval = 10
    private static var asked = false

    static func taskFinished(_ title: String, body: String, seconds: TimeInterval) {
        guard seconds >= minimumSeconds, !NSApp.isActive, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            if !asked {
                asked = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
