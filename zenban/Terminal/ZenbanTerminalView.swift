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

    // Agent detection buffers
    // Note: Ctrl+R history search sends commands directly to shell without going through inputBuffer.
    // The shell echoes the selected command to output, so we monitor outputBuffer for "claude".
    // However, Ctrl+R generates lots of terminal output (search UI, ANSI codes) that can overflow
    // the buffer or split keywords with escape codes. Solution:
    // 1. Strip ANSI codes before adding to buffer
    // 2. Use larger buffer (500 chars)
    // 3. agentDetectedInOutput flag persists once "claude" is seen, reset on Enter
    private var inputBuffer = ""
    private var outputBuffer = ""
    private let outputBufferMaxSize = 500
    private var agentDetectedInOutput = false

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

    private static let agentKeyword = "claude"

    // Regex to strip ANSI escape sequences (e.g., \e[32m, \e[0m)
    // Required because Ctrl+R history search wraps text in ANSI codes,
    // which can split "claude" into "cla\e[0mude" and break detection.
    // Static to share single instance across all terminals.
    private static let ansiPattern = try! NSRegularExpression(pattern: "\\x1B\\[[0-9;]*[A-Za-z]")

    private func stripAnsiCodes(_ str: String) -> String {
        let range = NSRange(str.startIndex..., in: str)
        return Self.ansiPattern.stringByReplacingMatches(in: str, range: range, withTemplate: "")
    }

    private func detectAgentInOutput(_ slice: ArraySlice<UInt8>) {
        guard !agentDetectedInOutput,
              let str = String(bytes: slice, encoding: .utf8) else { return }

        // Strip ANSI codes to prevent keyword splitting by escape sequences
        let cleanStr = stripAnsiCodes(str)
        outputBuffer.append(cleanStr)

        // Set flag when keyword found - flag persists until Enter is pressed
        // This handles Ctrl+R where keyword may appear early then get pushed out of buffer
        if outputBuffer.contains(Self.agentKeyword) {
            agentDetectedInOutput = true
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

        switch state {
        case .shell:
            // Detect agent from direct input ("claude ...") or output flag (Ctrl+R history)
            if trimmed.hasPrefix(Self.agentKeyword) || agentDetectedInOutput {
                transition(event: .agentDetected)
            }
            outputBuffer = ""
            agentDetectedInOutput = false

        case .agentActive:
            if !trimmed.isEmpty {
                triggerAgentResumed()
            }

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

    private func withCardContext(_ action: (UUID, UUID) -> Void) {
        guard let cardID = cardID, let boardID = boardID else { return }
        action(cardID, boardID)
    }

    private func sendNotification(title: String, body: String) {
        withCardContext { NotificationService.shared.showNotification(title: title, body: body, cardID: $0, boardID: $1) }
    }

    private func triggerTaskCompleted() {
        withCardContext { NotificationService.shared.triggerTaskCompleted(cardID: $0, boardID: $1) }
    }

    private func triggerAgentResumed() {
        withCardContext { NotificationService.shared.triggerAgentResumed(cardID: $0, boardID: $1) }
    }
}
