import AppKit
import Foundation
import Testing
@testable import zenban

@MainActor
struct AppDelegateTerminationTests {
    private enum WaitError: Error {
        case timedOut
    }

    private actor TerminationProbe {
        private(set) var cleanupCount = 0
        private(set) var replies: [Bool] = []
        private var continuation: CheckedContinuation<Void, Never>?

        func beginCleanup() async {
            cleanupCount += 1
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finishCleanup() {
            continuation?.resume()
            continuation = nil
        }

        func recordReply(_ allowsTermination: Bool) {
            replies.append(allowsTermination)
        }
    }

    @Test
    func applicationShouldTerminateUsesTerminateLaterAndRepliesAfterCleanup() async throws {
        let appDelegate = AppDelegate()
        let probe = TerminationProbe()
        appDelegate.configureApplicationTerminationHooksForTesting(
            cleanupHandler: {
                await probe.beginCleanup()
            },
            replyHandler: { allowsTermination in
                Task {
                    await probe.recordReply(allowsTermination)
                }
            }
        )
        defer {
            appDelegate.resetApplicationTerminationHooksForTesting()
            _ = appDelegate
        }

        let reply = appDelegate.applicationShouldTerminate(NSApplication.shared)

        #expect(reply == .terminateLater)
        try await waitUntil { await probe.cleanupCount == 1 }
        #expect(await probe.replies.isEmpty)

        await probe.finishCleanup()

        try await waitUntil { await probe.replies == [true] }
    }

    @Test
    func applicationShouldTerminateCoalescesDuplicateRequests() async throws {
        let appDelegate = AppDelegate()
        let probe = TerminationProbe()
        appDelegate.configureApplicationTerminationHooksForTesting(
            cleanupHandler: {
                await probe.beginCleanup()
            },
            replyHandler: { allowsTermination in
                Task {
                    await probe.recordReply(allowsTermination)
                }
            }
        )
        defer {
            appDelegate.resetApplicationTerminationHooksForTesting()
            _ = appDelegate
        }

        let firstReply = appDelegate.applicationShouldTerminate(NSApplication.shared)
        let secondReply = appDelegate.applicationShouldTerminate(NSApplication.shared)

        #expect(firstReply == .terminateLater)
        #expect(secondReply == .terminateLater)
        try await waitUntil { await probe.cleanupCount == 1 }

        await probe.finishCleanup()

        try await waitUntil { await probe.replies == [true] }
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw WaitError.timedOut
    }
}
