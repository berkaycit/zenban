//
//  GhosttyThemeParser.swift
//  zenban
//
//  Parser for Ghostty theme files to provide tmux mode style
//

import Foundation

nonisolated struct GhosttyThemeParser {
    private struct ParsedTheme {
        let foreground: String?
        let selectionBackground: String?
    }

    private static func parseTheme(contentsOf path: String) -> ParsedTheme? {
        guard let content = try? String(contentsOfFile: path) else {
            return nil
        }

        var foreground: String?
        var selectionBackground: String?

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }

            switch parts[0] {
            case "foreground":
                foreground = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            case "selection-background":
                selectionBackground = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            default:
                break
            }
        }

        return ParsedTheme(foreground: foreground, selectionBackground: selectionBackground)
    }

    /// Returns tmux mode-style string for selection highlighting
    /// Format: "fg=#RRGGBB,bg=#RRGGBB"
    static func loadTmuxModeStyle(named name: String) -> String {
        let fallbackStyle = "fg=#cdd6f4,bg=#45475a"

        guard let resourcePath = Bundle.main.resourcePath else {
            return fallbackStyle
        }

        let themePath = ((resourcePath as NSString)
            .appendingPathComponent("ghostty/themes") as NSString)
            .appendingPathComponent(name)

        guard let theme = parseTheme(contentsOf: themePath) else {
            return fallbackStyle
        }

        let fg = theme.foreground ?? "cdd6f4"
        let bg = theme.selectionBackground ?? "45475a"
        return "fg=#\(fg),bg=#\(bg)"
    }
}
