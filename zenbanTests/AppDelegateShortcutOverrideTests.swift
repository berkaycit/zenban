import AppKit
import Testing
@testable import zenban

@MainActor
struct AppDelegateShortcutOverrideTests {
    @Test
    func customShortcutOverrideConsumesCommandShiftR() throws {
        let appDelegate = AppDelegate()
        var invocationCount = 0
        var receivedCharactersIgnoringModifiers: String?

        appDelegate.zenbanShortcutOverrideHandler = { event in
            invocationCount += 1
            receivedCharactersIgnoringModifiers = event.charactersIgnoringModifiers?.lowercased()
            return true
        }

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "R",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 15
            )
        )

        #expect(appDelegate.debugHandleCustomShortcut(event: event))
        #expect(invocationCount == 1)
        #expect(receivedCharactersIgnoringModifiers == "r")
    }
}
