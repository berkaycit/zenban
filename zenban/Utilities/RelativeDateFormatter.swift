import Foundation

nonisolated final class RelativeDateFormatter: @unchecked Sendable {
    static let shared = RelativeDateFormatter()

    private let formatter: RelativeDateTimeFormatter
    private let lock = NSLock()

    private init() {
        formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
