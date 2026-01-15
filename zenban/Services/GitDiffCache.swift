import Foundation

actor GitDiffCache {
    struct CachedDiff {
        let lines: [DiffLine]
        let timestamp: Date
        let contentHash: String
    }

    private var cache: [String: CachedDiff] = [:]
    private var accessOrder: [String] = []
    private let maxCacheSize: Int
    private let maxDiffLines: Int
    private let maxCacheAge: TimeInterval

    init(maxCacheSize: Int = 50, maxDiffLines: Int = 10_000, maxCacheAge: TimeInterval = 300) {
        self.maxCacheSize = maxCacheSize
        self.maxDiffLines = maxDiffLines
        self.maxCacheAge = maxCacheAge
    }

    func getDiff(for file: String, contentHash: String? = nil) -> [DiffLine]? {
        guard let cached = cache[file] else { return nil }

        let isStale = Date().timeIntervalSince(cached.timestamp) > maxCacheAge
        let hashMismatch = contentHash.map { $0 != cached.contentHash } ?? false

        if isStale || hashMismatch {
            invalidate(file: file)
            return nil
        }

        updateAccessOrder(file)
        return cached.lines
    }

    func cacheDiff(_ lines: [DiffLine], for file: String, contentHash: String) {
        let truncatedLines = lines.count > maxDiffLines
            ? Array(lines.prefix(maxDiffLines)) + [
                DiffLine(
                    lineNumber: maxDiffLines,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    content: "... diff truncated (\(lines.count - maxDiffLines) more lines) ...",
                    type: .header
                )
              ]
            : lines

        cache[file] = CachedDiff(
            lines: truncatedLines,
            timestamp: Date(),
            contentHash: contentHash
        )
        updateAccessOrder(file)
        evictIfNeeded()
    }

    func contains(file: String) -> Bool {
        guard let cached = cache[file] else { return false }
        // Also check if cache is still fresh
        return Date().timeIntervalSince(cached.timestamp) <= maxCacheAge
    }

    func invalidate(file: String) {
        cache.removeValue(forKey: file)
        accessOrder.removeAll { $0 == file }
    }

    func invalidateAll() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    private func updateAccessOrder(_ file: String) {
        accessOrder.removeAll { $0 == file }
        accessOrder.append(file)
    }

    private func evictIfNeeded() {
        while cache.count > maxCacheSize, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }
}
