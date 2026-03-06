//
//  GhosttyConfig.swift
//  zenban
//
//  Parses user's ghostty config for background color and theme info
//

import Foundation
import AppKit

struct GhosttyConfig {
    enum ColorSchemePreference: Hashable {
        case light
        case dark
    }

    private static let loadCacheLock = NSLock()
    private static var cachedConfigsByColorScheme: [ColorSchemePreference: GhosttyConfig] = [:]

    var backgroundColor: NSColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
    var backgroundOpacity: Double = 1.0
    var foregroundColor: NSColor = .white
    var theme: String?

    static func load(
        preferredColorScheme: ColorSchemePreference? = nil,
        useCache: Bool = true
    ) -> GhosttyConfig {
        let resolvedColorScheme = preferredColorScheme ?? currentColorSchemePreference()
        if useCache, let cached = cachedLoad(for: resolvedColorScheme) {
            return cached
        }

        let loaded = loadFromDisk(preferredColorScheme: resolvedColorScheme)
        if useCache {
            storeCachedLoad(loaded, for: resolvedColorScheme)
        }
        return loaded
    }

    static func invalidateLoadCache() {
        loadCacheLock.lock()
        cachedConfigsByColorScheme.removeAll()
        loadCacheLock.unlock()
    }

    private static func cachedLoad(for colorScheme: ColorSchemePreference) -> GhosttyConfig? {
        loadCacheLock.lock()
        defer { loadCacheLock.unlock() }
        return cachedConfigsByColorScheme[colorScheme]
    }

    private static func storeCachedLoad(_ config: GhosttyConfig, for colorScheme: ColorSchemePreference) {
        loadCacheLock.lock()
        cachedConfigsByColorScheme[colorScheme] = config
        loadCacheLock.unlock()
    }

    private static func loadFromDisk(preferredColorScheme: ColorSchemePreference) -> GhosttyConfig {
        var config = GhosttyConfig()

        let configPaths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ].map { NSString(string: $0).expandingTildeInPath }

        for path in configPaths {
            if let contents = readConfigFile(at: path) {
                config.parse(contents)
            }
        }

        if let themeName = config.theme {
            config.loadTheme(themeName, preferredColorScheme: preferredColorScheme)
        }

        return config
    }

    mutating func parse(_ contents: String) {
        let lines = contents.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch key {
            case "theme":
                theme = value
            case "background":
                if let color = parseHexColor(value) {
                    backgroundColor = color
                }
            case "background-opacity":
                if let opacity = Double(value) {
                    backgroundOpacity = opacity
                }
            case "foreground":
                if let color = parseHexColor(value) {
                    foregroundColor = color
                }
            default:
                break
            }
        }
    }

    mutating func loadTheme(_ name: String, preferredColorScheme: ColorSchemePreference? = nil) {
        let resolved = Self.resolveThemeName(
            from: name,
            preferredColorScheme: preferredColorScheme ?? Self.currentColorSchemePreference()
        )

        for path in Self.themeSearchPaths(forThemeName: resolved) {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                parse(contents)
                return
            }
        }
    }

    static func currentColorSchemePreference() -> ColorSchemePreference {
        let bestMatch = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return bestMatch == .darkAqua ? .dark : .light
    }

    static func resolveThemeName(from rawThemeValue: String, preferredColorScheme: ColorSchemePreference) -> String {
        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil { fallbackTheme = entry }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light": if lightTheme == nil { lightTheme = value }
            case "dark": if darkTheme == nil { darkTheme = value }
            default: if fallbackTheme == nil { fallbackTheme = value }
            }
        }

        switch preferredColorScheme {
        case .light: if let lightTheme { return lightTheme }
        case .dark: if let darkTheme { return darkTheme }
        }

        return fallbackTheme ?? darkTheme ?? lightTheme
            ?? rawThemeValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func themeSearchPaths(forThemeName themeName: String) -> [String] {
        var paths: [String] = []
        let env = ProcessInfo.processInfo.environment

        func appendUniquePath(_ path: String?) {
            guard let path else { return }
            let expanded = NSString(string: path).expandingTildeInPath
            guard !expanded.isEmpty, !paths.contains(expanded) else { return }
            paths.append(expanded)
        }

        // Ghostty resources dir
        if let resourcesDir = env["GHOSTTY_RESOURCES_DIR"] {
            appendUniquePath(
                URL(fileURLWithPath: resourcesDir)
                    .appendingPathComponent("themes/\(themeName)").path
            )
        }

        // App bundle resources
        appendUniquePath(
            Bundle.main.resourceURL?
                .appendingPathComponent("ghostty/themes/\(themeName)").path
        )

        // Installed Ghostty app
        appendUniquePath("/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(themeName)")

        // User config themes
        appendUniquePath("~/.config/ghostty/themes/\(themeName)")
        appendUniquePath("~/Library/Application Support/com.mitchellh.ghostty/themes/\(themeName)")

        return paths
    }

    private static func readConfigFile(at path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber, size.intValue == 0 {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func parseHexColor(_ hex: String) -> NSColor? {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: sanitized).scanHexInt64(&rgb) else { return nil }

        return NSColor(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
