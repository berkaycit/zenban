import Foundation
import UserNotifications
import AppKit
import OSLog

enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .unknown, .notDetermined, .denied:
            false
        }
    }
}

// Removing notifications can synchronously block on usernoted. Keep it off the main thread.
extension UNUserNotificationCenter {
    private static let zenbanRemovalQueue = DispatchQueue(
        label: "com.berkaycit.zenban.notification-removal",
        qos: .utility
    )

    func removeDeliveredNotificationsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.zenbanRemovalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func removePendingNotificationRequestsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.zenbanRemovalQueue.async {
            self.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private enum AuthorizationRequestOrigin {
        case automaticStartup
        case notificationDelivery

        var isAutomatic: Bool { true }
    }

    private static let logger = Logger(subsystem: "com.berkaycit.zenban", category: "NotificationService")

    var onNotificationClicked: ((UUID, UUID) -> Void)?
    var activeSelectionProvider: (() -> (boardID: UUID?, cardID: UUID?))?

    private let center = UNUserNotificationCenter.current()
    private var authorizationState: NotificationAuthorizationState = .unknown
    private var hasRequestedAutomaticAuthorization = false
    private var hasDeferredAuthorizationRequest = false

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        refreshAuthorizationStatus()
        ensureAuthorization(origin: .automaticStartup) { _ in }
    }

    func showNotification(
        title: String,
        body: String,
        cardID: UUID,
        boardID: UUID
    ) {
        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self, authorized else { return }

            let identifier = Self.notificationIdentifier(for: cardID)
            self.clearNotificationRequests(forIdentifier: identifier)

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = [
                "cardID": cardID.uuidString,
                "boardID": boardID.uuidString,
            ]

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    Self.logger.error("Failed to schedule notification: \(error.localizedDescription, privacy: .public)")
                    self.refreshAuthorizationStatus()
                }
            }
        }
    }

    func handleApplicationDidBecomeActive() {
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .automaticStartup) { _ in }
        } else {
            refreshAuthorizationStatus()
        }

        if let cardID = activeSelectionProvider?().cardID {
            clearNotifications(for: cardID)
        }
    }

    func clearNotifications(for cardID: UUID) {
        clearNotificationRequests(forIdentifier: Self.notificationIdentifier(for: cardID))
    }

    static func authorizationState(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .unknown
        }
    }

    static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    private static func notificationIdentifier(for cardID: UUID) -> String {
        "zenban.task-complete.\(cardID.uuidString)"
    }

    private func clearNotificationRequests(forIdentifier identifier: String) {
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [identifier])
        center.removePendingNotificationRequestsOffMain(withIdentifiers: [identifier])
    }

    private func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
            }
        }
    }

    private func ensureAuthorization(
        origin: AuthorizationRequestOrigin,
        completion: @escaping (Bool) -> Void
    ) {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)

                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true)

                case .denied:
                    completion(false)

                case .notDetermined:
                    if origin.isAutomatic,
                       Self.shouldDeferAutomaticAuthorizationRequest(
                        status: settings.authorizationStatus,
                        isAppActive: AppFocusState.isAppActive()
                       ) {
                        self.hasDeferredAuthorizationRequest = true
                        completion(false)
                    } else {
                        self.requestAuthorizationIfNeeded(origin: origin, completion: completion)
                    }

                @unknown default:
                    completion(false)
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: AuthorizationRequestOrigin,
        completion: @escaping (Bool) -> Void
    ) {
        guard !origin.isAutomatic || !hasRequestedAutomaticAuthorization else {
            completion(authorizationState.allowsDelivery)
            return
        }

        if origin.isAutomatic {
            hasRequestedAutomaticAuthorization = true
        }
        hasDeferredAuthorizationRequest = false

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                if let error {
                    Self.logger.error("Notification authorization error: \(error.localizedDescription, privacy: .public)")
                }

                if granted {
                    self.authorizationState = .authorized
                } else {
                    self.refreshAuthorizationStatus()
                }

                completion(granted)
            }
        }
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
            clearNotifications(for: cardID)

            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                Task { @MainActor in
                    onNotificationClicked?(boardID, cardID)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }
}
