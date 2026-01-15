import Foundation
import Clibgit2

/// Manages libgit2 library lifecycle
/// Thread-safe singleton that initializes libgit2 once and shuts it down on app termination
nonisolated final class Libgit2Service: @unchecked Sendable {
    static let shared = Libgit2Service()

    private let lock = NSLock()
    private var isInitialized = false

    private init() {
        initialize()
    }

    deinit {
        shutdown()
    }

    /// Initialize libgit2 library (called automatically on first access)
    private func initialize() {
        lock.lock()
        defer { lock.unlock() }

        guard !isInitialized else { return }

        let result = git_libgit2_init()
        if result >= 0 {
            isInitialized = true
        }
    }

    /// Shutdown libgit2 library
    private func shutdown() {
        lock.lock()
        defer { lock.unlock() }

        guard isInitialized else { return }

        git_libgit2_shutdown()
        isInitialized = false
    }

    /// Ensure libgit2 is initialized before any operation
    func ensureInitialized() {
        if !isInitialized {
            initialize()
        }
    }

}
