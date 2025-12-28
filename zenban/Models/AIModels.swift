import Foundation

// MARK: - Result Types

struct CommitMessageResult {
    let summary: String
    let description: String

    static let empty = CommitMessageResult(summary: "", description: "")
}

// MARK: - Parser Protocol

protocol CommitMessageParser {
    func parse(_ response: String) -> CommitMessageResult
}

// MARK: - Default Parser Implementation

/// Parser for Claude's commit message response format
/// Handles multiple formats with fallback strategies
struct DefaultCommitMessageParser: CommitMessageParser {

    func parse(_ response: String) -> CommitMessageResult {
        // Strategy 1: Look for SUMMARY:/DESCRIPTION: markers
        if let structured = parseStructured(response) {
            return structured
        }

        // Strategy 2: First non-empty line as summary, rest as description
        if let simple = parseSimple(response) {
            return simple
        }

        // Strategy 3: Use entire response as summary (truncated to 72 chars)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitMessageResult(
            summary: String(trimmed.prefix(72)),
            description: ""
        )
    }

    // MARK: - Parsing Strategies

    /// Parse response with explicit SUMMARY:/DESCRIPTION: markers
    private func parseStructured(_ response: String) -> CommitMessageResult? {
        var summary: String?
        var descriptionLines: [String] = []
        var inDescription = false

        let lines = response.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()

            // Check for SUMMARY marker (handles "SUMMARY:", "Summary:", "SUMMARY -", etc.)
            if upper.hasPrefix("SUMMARY") {
                let afterMarker = extractAfterMarker(trimmed, markerLength: 7)
                if !afterMarker.isEmpty {
                    summary = afterMarker
                }
                inDescription = false
            }
            // Check for DESCRIPTION marker
            else if upper.hasPrefix("DESCRIPTION") {
                let afterMarker = extractAfterMarker(trimmed, markerLength: 11)
                if !afterMarker.isEmpty {
                    descriptionLines.append(afterMarker)
                }
                inDescription = true
            }
            // Continue collecting description lines
            else if inDescription {
                descriptionLines.append(trimmed)
            }
        }

        // Only return if we found a summary
        guard let foundSummary = summary, !foundSummary.isEmpty else {
            return nil
        }

        // Clean up description - trim empty lines from start/end
        while descriptionLines.first?.isEmpty == true {
            descriptionLines.removeFirst()
        }
        while descriptionLines.last?.isEmpty == true {
            descriptionLines.removeLast()
        }

        return CommitMessageResult(
            summary: foundSummary,
            description: descriptionLines.joined(separator: "\n")
        )
    }

    /// Extract content after a marker (handles ":", "-", "=", or space separators)
    private func extractAfterMarker(_ line: String, markerLength: Int) -> String {
        let afterMarker = String(line.dropFirst(markerLength))
        let trimmed = afterMarker.trimmingCharacters(in: .whitespaces)

        // Remove leading separator if present
        if let first = trimmed.first, [":", "-", "="].contains(first) {
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        return trimmed
    }

    /// Parse response as first line = summary, rest = description
    private func parseSimple(_ response: String) -> CommitMessageResult? {
        let lines = response.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Find first non-empty line as summary
        guard let firstNonEmpty = lines.first(where: { !$0.isEmpty }) else {
            return nil
        }

        // Rest becomes description (skip summary line and leading empty lines)
        let afterSummary = lines.drop(while: { $0.isEmpty || $0 == firstNonEmpty })
        let description = afterSummary.drop(while: { $0.isEmpty })
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CommitMessageResult(
            summary: String(firstNonEmpty.prefix(72)),
            description: description
        )
    }
}

