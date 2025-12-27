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

    private var isAgentRunning = false
    private var inputBuffer = ""
    private var outputBuffer = ""
    private let outputBufferMaxSize = 500

    deinit {
        idleTimer?.invalidate()
    }

    override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            hasBeenFocused = true
            notificationSent = false
            activityByteCount = 0
        }
        return response
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        processInput(data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        // Check for claude in output (handles Ctrl+R, history, etc.)
        if !isAgentRunning {
            if let str = String(bytes: slice, encoding: .utf8) {
                outputBuffer.append(str)
                if outputBuffer.count > outputBufferMaxSize {
                    outputBuffer = String(outputBuffer.suffix(outputBufferMaxSize))
                }
                if outputBuffer.contains("claude") {
                    isAgentRunning = true
                    notificationSent = false
                    activityByteCount = 0
                    outputBuffer = ""
                }
            }
            return
        }

        guard !notificationSent else { return }
        activityByteCount += slice.count
        scheduleIdleCheck()
    }

    // MARK: - Input Processing

    private func processInput(_ data: ArraySlice<UInt8>) {
        for byte in data {
            switch byte {
            case 0x03: // Ctrl+C
                if isAgentRunning {
                    isAgentRunning = false
                    if notificationSent {
                        triggerTaskCompleted()
                    }
                }
                inputBuffer = ""
            case 0x0D: // Enter
                handleCommand(inputBuffer)
                inputBuffer = ""
            case 0x7F: // Backspace
                if !inputBuffer.isEmpty {
                    inputBuffer.removeLast()
                }
            default:
                if byte >= 0x20 && byte < 0x7F {
                    inputBuffer.append(Character(UnicodeScalar(byte)))
                }
            }
        }
    }

    private func handleCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("claude") {
            isAgentRunning = true
            notificationSent = false
            activityByteCount = 0
        } else if isAgentRunning && notificationSent {
            notificationSent = false
            activityByteCount = 0
            triggerAgentResumed()
        }
    }

    // MARK: - Idle Detection

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
        guard isAgentRunning, !notificationSent, hasBeenFocused, activityByteCount >= minActivityBytes else {
            activityByteCount = 0
            return
        }
        notificationSent = true
        activityByteCount = 0

        if !isFirstResponder {
            sendNotification(title: cardTitle ?? "Terminal", body: "Task completed")
        }
        triggerTaskCompleted()
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String) {
        guard let cardID = cardID, let boardID = boardID else { return }
        NotificationService.shared.showNotification(title: title, body: body, cardID: cardID, boardID: boardID)
    }

    private func triggerTaskCompleted() {
        guard let cardID = cardID, let boardID = boardID else { return }
        NotificationService.shared.triggerTaskCompleted(cardID: cardID, boardID: boardID)
    }

    private func triggerAgentResumed() {
        guard let cardID = cardID, let boardID = boardID else { return }
        NotificationService.shared.triggerAgentResumed(cardID: cardID, boardID: boardID)
    }
}
