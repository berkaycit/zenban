import Foundation
import os
import GhosttyKit

/// Ghostty namespace for terminal embedding.
public struct Ghostty {
    /// Logger for Ghostty operations
    public static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zenban",
        category: "ghostty"
    )
}

// MARK: - C Type Extensions

// Note: ghostty_surface_t is an opaque pointer type (UnsafeMutableRawPointer)
// which is already Sendable in Swift
