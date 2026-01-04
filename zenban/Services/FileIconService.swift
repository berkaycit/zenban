import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FileIconService {
    static let shared = FileIconService()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    func icon(forFile filePath: String, size: CGSize) -> NSImage {
        let cacheKey = "\(filePath)_\(Int(size.width))x\(Int(size.height))" as NSString

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let icon = FileManager.default.fileExists(atPath: filePath)
            ? NSWorkspace.shared.icon(forFile: filePath)
            : NSWorkspace.shared.icon(for: .data)

        let resizedIcon = icon.resized(to: size)
        let cost = Int(size.width * size.height * 4)
        cache.setObject(resizedIcon, forKey: cacheKey, cost: cost)
        return resizedIcon
    }
}

extension NSImage {
    func resized(to targetSize: CGSize) -> NSImage {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        defer { newImage.unlockFocus() }

        let sourceRect = NSRect(origin: .zero, size: size)
        let targetRect = NSRect(origin: .zero, size: targetSize)
        draw(in: targetRect, from: sourceRect, operation: .copy, fraction: 1.0)
        return newImage
    }
}
