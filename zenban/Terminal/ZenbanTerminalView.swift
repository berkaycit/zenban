import Foundation
import SwiftTerm
import AppKit

// MARK: - Terminal State Machine

private enum TerminalState {
    case shell        // Normal shell, agent not running
    case agentActive  // Claude is running, monitoring output
    case agentIdle    // Task completed, card in "In Review"
}

private enum TerminalEvent {
    case agentDetected    // "claude" found in input or output
    case taskCompleted    // 2 seconds idle after output
    case newMessageSent   // User sent a new message while idle
    case agentExited      // Ctrl+C pressed
}

// MARK: - ZenbanTerminalView

final class ZenbanTerminalView: LocalProcessTerminalView {
    var cardID: UUID?
    var boardID: UUID?
    var cardTitle: String?

    // State machine
    private var state: TerminalState = .shell {
        didSet {
            if oldValue != state {
                handleStateChange(from: oldValue, to: state)
            }
        }
    }

    // Idle detection
    private var idleWorkItem: DispatchWorkItem?
    private var activityByteCount: Int = 0
    private let idleThreshold: TimeInterval = 2.0
    private let minActivityBytes: Int = 10

    // Input/Output buffers for agent detection
    private var inputBuffer = ""
    private var outputBuffer = ""
    private let outputBufferMaxSize = 100

    // Focus tracking
    private var hasBeenFocused = false

    deinit {
        idleWorkItem?.cancel()
    }

    // MARK: - State Machine

    private func transition(event: TerminalEvent) {
        let newState: TerminalState? = {
            switch (state, event) {
            case (.shell, .agentDetected):
                return .agentActive

            case (.agentActive, .taskCompleted):
                return .agentIdle

            case (.agentActive, .agentExited):
                return .shell

            case (.agentIdle, .newMessageSent):
                return .agentActive

            case (.agentIdle, .agentExited):
                return .shell

            default:
                return nil
            }
        }()

        if let newState = newState {
            state = newState
        }
    }

    private func handleStateChange(from oldState: TerminalState, to newState: TerminalState) {
        idleWorkItem?.cancel()
        idleWorkItem = nil

        switch (oldState, newState) {
        case (_, .agentActive):
            activityByteCount = 0
            outputBuffer = ""
            if oldState == .agentIdle {
                triggerAgentResumed()
            }

        case (.agentActive, .agentIdle):
            if !isFirstResponder {
                sendNotification(title: cardTitle ?? "Terminal", body: "Task completed")
            }
            triggerTaskCompleted()

        default:
            break
        }
    }

    // MARK: - NSResponder

    override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            hasBeenFocused = true
        }
        return response
    }

    // MARK: - Terminal I/O

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        processInput(data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        switch state {
        case .shell:
            detectAgentInOutput(slice)

        case .agentActive:
            activityByteCount += slice.count
            scheduleIdleCheck()

        case .agentIdle:
            break
        }
    }

    // MARK: - Agent Detection

    private let agentKeyword = "claude"

    private func detectAgentInOutput(_ slice: ArraySlice<UInt8>) {
        guard let str = String(bytes: slice, encoding: .utf8) else { return }

        let oldLength = outputBuffer.count
        outputBuffer.append(str)

        // Search only in newly added portion + keyword overlap
        let searchStart = max(0, oldLength - agentKeyword.count)
        let searchStartIndex = outputBuffer.index(outputBuffer.startIndex, offsetBy: searchStart)
        if outputBuffer[searchStartIndex...].contains(agentKeyword) {
            transition(event: .agentDetected)
        }

        if outputBuffer.count > outputBufferMaxSize {
            outputBuffer = String(outputBuffer.suffix(outputBufferMaxSize))
        }
    }

    // MARK: - Input Processing

    private func processInput(_ data: ArraySlice<UInt8>) {
        for byte in data {
            switch byte {
            case 0x03: // Ctrl+C
                transition(event: .agentExited)
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

        switch state {
        case .shell:
            if trimmed.hasPrefix("claude") {
                transition(event: .agentDetected)
            }

        case .agentActive:
            break

        case .agentIdle:
            transition(event: .newMessageSent)
        }
    }

    // MARK: - Idle Detection

    private func scheduleIdleCheck() {
        idleWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.onBecameIdle()
        }
        idleWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + idleThreshold, execute: workItem)
    }

    private var isFirstResponder: Bool {
        window?.firstResponder === self
    }

    private func onBecameIdle() {
        guard state == .agentActive,
              hasBeenFocused,
              activityByteCount >= minActivityBytes else {
            return
        }

        transition(event: .taskCompleted)
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
