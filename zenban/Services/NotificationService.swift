import Foundation
import UserNotifications
import AppKit

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    var onNotificationClicked: ((UUID, UUID) -> Void)?
    var onTaskCompleted: ((UUID, UUID) -> Void)?
    var onAgentResumed: ((UUID, UUID) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    func showNotification(title: String, body: String, cardID: UUID, boardID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "cardID": cardID.uuidString,
            "boardID": boardID.uuidString
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func triggerTaskCompleted(cardID: UUID, boardID: UUID) {
        onTaskCompleted?(cardID, boardID)
    }

    func triggerAgentResumed(cardID: UUID, boardID: UUID) {
        onAgentResumed?(cardID, boardID)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        if let cardIDString = userInfo["cardID"] as? String,
           let boardIDString = userInfo["boardID"] as? String,
           let cardID = UUID(uuidString: cardIDString),
           let boardID = UUID(uuidString: boardIDString) {
            Task { @MainActor in
                onNotificationClicked?(boardID, cardID)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
