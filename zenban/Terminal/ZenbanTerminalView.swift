import Foundation
import SwiftTerm
import AppKit

final class ZenbanTerminalView: LocalProcessTerminalView {
    var cardID: UUID?
    var boardID: UUID?
    var cardTitle: String?

    private var idleTimer: Timer?
    private var activityByteCount: Int = 0
    private var notificationSent = false
    private var hasBeenFocused = false
    private let idleThreshold: TimeInterval = 2.0
    private let minActivityBytes: Int = 10

    deinit {
        idleTimer?.invalidate()
    }

    override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            hasBeenFocused = true
            if notificationSent {
                notificationSent = false
                activityByteCount = 0
            }
        }
        return response
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        guard !notificationSent else { return }
        activityByteCount += slice.count
        scheduleIdleCheck()
    }

    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleThreshold, repeats: false) { [weak self] _ in
            self?.onBecameIdle()
        }
    }

    private var isFirstResponder: Bool {
        window?.firstResponder === self
    }

    private func onBecameIdle() {
        idleTimer = nil
        guard !notificationSent, hasBeenFocused, activityByteCount >= minActivityBytes, !isFirstResponder else {
            activityByteCount = 0
            return
        }
        notificationSent = true
        activityByteCount = 0
        sendNotification(title: cardTitle ?? "Terminal", body: "Task completed")
    }

    private func sendNotification(title: String, body: String) {
        guard let cardID = cardID, let boardID = boardID else { return }
        NotificationService.shared.showNotification(title: title, body: body, cardID: cardID, boardID: boardID)
    }
}
