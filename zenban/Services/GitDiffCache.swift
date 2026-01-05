import Foundation

actor GitDiffCache {
    private var cache: [String: [DiffLine]] = [:]
    private var accessOrder: [String] = []
    private let maxCacheSize: Int
    private let maxDiffLines: Int

    init(maxCacheSize: Int = 50, maxDiffLines: Int = 10_000) {
        self.maxCacheSize = maxCacheSize
        self.maxDiffLines = maxDiffLines
    }

    func getDiff(for file: String) -> [DiffLine]? {
        guard let cached = cache[file] else { return nil }
        updateAccessOrder(file)
        return cached
    }

    func cacheDiff(_ lines: [DiffLine], for file: String) {
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

        cache[file] = truncatedLines
        updateAccessOrder(file)
        evictIfNeeded()
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
