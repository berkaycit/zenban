import Foundation
import Testing
@testable import zenban

@Suite(.serialized)
@MainActor
struct TerminalNotificationStoreDuplicateTests {
    @Test
    func sameSurfaceSameContentNotificationKeepsExistingAndDoesNotScheduleAgain() throws {
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
            body: "Done"
        )
        let retainedNotification = try #require(notificationStore.notifications.first)

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.count == 1)
        #expect(retainedNotification.id == firstNotification.id)
        #expect(observer.addedIds == [firstNotification.id])
    }

    @Test
    func sameSurfaceDifferentContentReplacesExistingAndSchedulesAgain() throws {
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
            body: "Waiting"
        )
        let replacementNotification = try #require(notificationStore.notifications.first)

        #expect(deliveryCount == 2)
        #expect(notificationStore.notifications.count == 1)
        #expect(replacementNotification.id != firstNotification.id)
        #expect(observer.addedIds == [firstNotification.id, replacementNotification.id])
    }

    @Test
    func genericWaitingDoesNotReplaceReadCompletedNotificationOnSameSurface() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Implementation finished"
        )
        let completedNotification = try #require(notificationStore.notifications.first)
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId, source: "test")

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude is waiting for your input"
        )

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.count == 1)
        #expect(notificationStore.notifications.first?.id == completedNotification.id)
        #expect(notificationStore.notifications.first?.isRead == true)
        #expect(!notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId))
    }

    @Test
    func genericWaitingDoesNotRescheduleOverUnreadCompletedNotificationOnSameSurface() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Implementation finished"
        )
        let completedNotification = try #require(notificationStore.notifications.first)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude is waiting for your input"
        )

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.count == 1)
        #expect(notificationStore.notifications.first?.id == completedNotification.id)
        #expect(notificationStore.notifications.first?.isRead == false)
        #expect(notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId))
    }

    @Test
    func meaningfulWaitingReplacesGenericWaitingOnSameSurface() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude is waiting for your input"
        )
        let genericNotification = try #require(notificationStore.notifications.first)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Which deployment target should I use?"
        )
        let replacementNotification = try #require(notificationStore.notifications.first)

        #expect(deliveryCount == 2)
        #expect(notificationStore.notifications.count == 1)
        #expect(replacementNotification.id != genericNotification.id)
        #expect(replacementNotification.body == "Which deployment target should I use?")
    }

    @Test
    func errorAndPermissionReplaceGenericWaitingOnSameSurface() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude is waiting for your input"
        )
        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Error",
            body: "Build failed"
        )
        let errorNotification = try #require(notificationStore.notifications.first)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Claude is waiting for your input"
        )
        #expect(notificationStore.notifications.first?.id == errorNotification.id)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Permission",
            body: "Approval needed"
        )
        let permissionNotification = try #require(notificationStore.notifications.first)

        #expect(deliveryCount == 3)
        #expect(notificationStore.notifications.count == 1)
        #expect(permissionNotification.id != errorNotification.id)
        #expect(permissionNotification.subtitle == "Permission")
    }

    @Test
    func readSameSurfaceSameContentNotificationDoesNotBecomeUnreadAgain() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Already read"
        )
        let firstNotification = try #require(notificationStore.notifications.first)
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId, source: "test")

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Already read"
        )

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.count == 1)
        #expect(notificationStore.notifications.first?.id == firstNotification.id)
        #expect(notificationStore.notifications.first?.isRead == true)
        #expect(!notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId))
    }

    @Test
    func readSameContentNotificationDoesNotDeliverAgainAfterSurfaceChanges() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let firstSurfaceId = UUID()
        let secondSurfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: firstSurfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Already read"
        )
        notificationStore.markRead(forTabId: tabId, surfaceId: firstSurfaceId, source: "test")

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: secondSurfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Already read"
        )

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.count == 1)
        #expect(notificationStore.notifications.first?.surfaceId == firstSurfaceId)
        #expect(notificationStore.notifications.first?.isRead == true)
        #expect(!notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: secondSurfaceId))
    }

    @Test
    func readClearedSameContentNotificationDoesNotDeliverAgainOnNewSurface() throws {
        let notificationStore = TerminalNotificationStore.shared
        var deliveryCount = 0
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveryCount += 1
        }
        notificationStore.replaceNotificationsForTesting([])
        AppFocusState.overrideIsFocused = false
        defer {
            AppFocusState.overrideIsFocused = nil
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
        }

        let tabId = UUID()
        let firstSurfaceId = UUID()
        let secondSurfaceId = UUID()

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: firstSurfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Already read"
        )
        notificationStore.markRead(forTabId: tabId, surfaceId: firstSurfaceId, source: "test")
        notificationStore.clearNotifications(forTabId: tabId, surfaceId: firstSurfaceId)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: secondSurfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Already read"
        )

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.isEmpty)
        #expect(!notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: secondSurfaceId))
    }

    @Test
    func queuedReadClearedSameContentNotificationDoesNotDeliverAgainOnNewSurface() throws {
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

        let workspace = try #require(tabManager.tabs.first)
        let tabId = workspace.id
        let firstSurfaceId = try #require(workspace.focusedPanelId)
        let secondSurfaceId = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: true)?.id)

        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: firstSurfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Already read"
        )
        notificationStore.markRead(forTabId: tabId, surfaceId: firstSurfaceId, source: "test")
        notificationStore.clearNotifications(forTabId: tabId, surfaceId: firstSurfaceId)

        TerminalMutationBus.shared.enqueueNotification(
            tabId: tabId,
            surfaceId: secondSurfaceId,
            title: "Claude Code",
            subtitle: "Waiting",
            body: "Already read"
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.isEmpty)
        #expect(!notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: secondSurfaceId))
    }

    @Test
    func focusedReadIndicatorMakesNotificationVisibleWithoutUnreadState() {
        let notificationStore = TerminalNotificationStore.shared
        notificationStore.replaceNotificationsForTesting([])
        defer {
            notificationStore.replaceNotificationsForTesting([])
        }

        let tabId = UUID()
        let surfaceId = UUID()

        notificationStore.setFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)

        #expect(notificationStore.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: surfaceId))
        #expect(!notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId))
        #expect(notificationStore.focusedReadIndicatorSurfaceId(forTabId: tabId) == surfaceId)
    }

    @Test
    func markReadForSurfaceClearsFocusedIndicatorAndPendingQueue() throws {
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
        let surfaceId = UUID()

        TerminalMutationBus.shared.enqueueNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Queued"
        )
        notificationStore.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Done"
        )
        notificationStore.setFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)

        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId, source: "test")
        TerminalMutationBus.shared.drainForTesting()

        #expect(deliveryCount == 1)
        #expect(notificationStore.notifications.first?.isRead == true)
        #expect(!notificationStore.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: surfaceId))
        #expect(notificationStore.focusedReadIndicatorSurfaceId(forTabId: tabId) == nil)
    }

    @Test
    func clearSurfaceClearsFocusedIndicatorAndQueuedNotification() throws {
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
        let surfaceId = UUID()

        TerminalMutationBus.shared.enqueueNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Build finished",
            subtitle: "Workspace notification",
            body: "Queued"
        )
        notificationStore.setFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)

        notificationStore.clearNotifications(forTabId: tabId, surfaceId: surfaceId)
        TerminalMutationBus.shared.drainForTesting()

        #expect(deliveryCount == 0)
        #expect(notificationStore.notifications.isEmpty)
        #expect(notificationStore.focusedReadIndicatorSurfaceId(forTabId: tabId) == nil)
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
