import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FileIconService {
    static let shared = FileIconService()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // Increased limits for better cache hit rate
        cache.countLimit = 1000
        // Cost is calculated as width * height * 4 bytes (RGBA)
        cache.totalCostLimit = 100 * 1024 * 1024
    }

    func icon(forFile filePath: String, size: CGSize) -> NSImage {
        let sizeKey = "\(Int(size.width))x\(Int(size.height))"
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory)
        let isDir = exists && isDirectory.boolValue

        let cacheKey: NSString
        if isDir {
            cacheKey = "folder_\(sizeKey)" as NSString
        } else {
            let ext = (filePath as NSString).pathExtension.lowercased()
            let nameKey = ext.isEmpty ? (filePath as NSString).lastPathComponent.lowercased() : ext
            cacheKey = "\(nameKey)_\(sizeKey)" as NSString
        }

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let icon: NSImage
        if isDir {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else {
            let ext = (filePath as NSString).pathExtension.lowercased()
            if let type = UTType(filenameExtension: ext) {
                icon = NSWorkspace.shared.icon(for: type)
            } else if exists {
                icon = NSWorkspace.shared.icon(forFile: filePath)
            } else {
                icon = NSWorkspace.shared.icon(for: .data)
            }
        }

        let resizedIcon = icon.resized(to: size)
        cache.setObject(resizedIcon, forKey: cacheKey, cost: Int(size.width * size.height * 4))
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
