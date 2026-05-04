import Foundation
import Testing
@testable import zenban

@MainActor
struct TerminalNotificationStoreDuplicateTests {
    @Test
    func unreadDuplicateNotificationIsNotDeliveredAgain() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        var suppressedFeedbackCount = 0
        let observer = NotificationStoreObserverSpy()
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in
            suppressedFeedbackCount += 1
        }
        notificationStore.observer = observer
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.observer = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetSuppressedNotificationFeedbackHandlerForTesting()
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )
        let firstNotification = try #require(notificationStore.notifications.first)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )

        #expect(deliveryCount == 1)
        #expect(suppressedFeedbackCount == 0)
        #expect(notificationStore.notifications.count == 1)
        #expect(notificationStore.notifications.first?.id == firstNotification.id)
        #expect(observer.addedIds == [firstNotification.id])
    }

    @Test
    func readDuplicateNotificationCanBeDeliveredAgain() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        let observer = NotificationStoreObserverSpy()
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.observer = observer
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.observer = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )
        let firstNotification = try #require(notificationStore.notifications.first)

        notificationStore.markRead(id: firstNotification.id)
        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )
        let secondNotification = try #require(notificationStore.notifications.first)

        #expect(deliveryCount == 2)
        #expect(notificationStore.notifications.count == 1)
        #expect(secondNotification.id != firstNotification.id)
        #expect(!secondNotification.isRead)
        #expect(observer.addedIds.count == 2)
        #expect(observer.addedIds.first == firstNotification.id)
        #expect(observer.addedIds.last == secondNotification.id)
    }

    @Test
    func changedNotificationContentIsNotSuppressed() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        let observer = NotificationStoreObserverSpy()
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.observer = observer
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.observer = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )
        let firstNotification = try #require(notificationStore.notifications.first)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done with warnings"
        )
        let bodyChangedNotification = try #require(notificationStore.notifications.first)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Agent notification",
            body: "Done with warnings"
        )
        let subtitleChangedNotification = try #require(notificationStore.notifications.first)

        #expect(deliveryCount == 3)
        #expect(notificationStore.notifications.count == 1)
        #expect(bodyChangedNotification.id != firstNotification.id)
        #expect(subtitleChangedNotification.id != bodyChangedNotification.id)
        #expect(observer.addedIds.count == 3)
    }

    @Test
    func queuedUnreadDuplicateNotificationIsNotDeliveredAgain() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        appDelegate.tabManager = tabManager
        defer {
            TerminalMutationBus.shared.setDrainsSuspendedForTesting(false)
            AppFocusState.overrideIsFocused = nil
            appDelegate.tabManager = nil
            if AppDelegate.shared === appDelegate {
                AppDelegate.shared = previousAppDelegate
            }
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = try #require(tabManager.tabs.first?.id)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: nil,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )
        let firstNotification = try #require(notificationStore.notifications.first)

        TerminalMutationBus.shared.enqueueNotification(
            tabId: tabId,
            surfaceId: nil,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.count == 1)
        #expect(notificationStore.notifications.first?.id == firstNotification.id)
    }
}

@MainActor
private final class NotificationStoreObserverSpy: TerminalNotificationStoreObserver {
    var addedIds: [UUID] = []

    func terminalNotificationStore(
        _ store: TerminalNotificationStore,
        didAdd notification: TerminalNotification
    ) {
        addedIds.append(notification.id)
    }
}
