import SwiftUI

struct DiffContentView: View {
    let diffText: String

    private var parsedHunks: [DiffHunk] {
        parseDiff(diffText)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(parsedHunks.enumerated()), id: \.offset) { _, hunk in
                // Hunk header
                Text(hunk.header)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))

                // Split view for this hunk
                HStack(spacing: 0) {
                    // Left side - old (deletions)
                    VStack(spacing: 0) {
                        ForEach(Array(hunk.leftLines.enumerated()), id: \.offset) { _, line in
                            SplitDiffLineView(line: line, side: .left)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

                    // Right side - new (additions)
                    VStack(spacing: 0) {
                        ForEach(Array(hunk.rightLines.enumerated()), id: \.offset) { _, line in
                            SplitDiffLineView(line: line, side: .right)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: - Parsing

    private func parseDiff(_ text: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var currentHunk: DiffHunk?
        var leftLineNum = 0
        var rightLineNum = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("@@") {
                // Save previous hunk
                if let hunk = currentHunk {
                    hunks.append(hunk)
                }

                // Parse line numbers from hunk header
                let (oldStart, newStart) = parseHunkHeader(line)
                leftLineNum = oldStart
                rightLineNum = newStart
                currentHunk = DiffHunk(header: line, leftLines: [], rightLines: [])
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") ||
                      line.hasPrefix("---") || line.hasPrefix("+++") {
                continue
            } else if var hunk = currentHunk {
                if line.hasPrefix("+") {
                    // Addition - only on right side
                    let content = String(line.dropFirst())
                    hunk.rightLines.append(SplitLine(lineNumber: rightLineNum, content: content, type: .addition))
                    hunk.leftLines.append(SplitLine(lineNumber: nil, content: "", type: .empty))
                    rightLineNum += 1
                } else if line.hasPrefix("-") {
                    // Deletion - only on left side
                    let content = String(line.dropFirst())
                    hunk.leftLines.append(SplitLine(lineNumber: leftLineNum, content: content, type: .deletion))
                    hunk.rightLines.append(SplitLine(lineNumber: nil, content: "", type: .empty))
                    leftLineNum += 1
                } else {
                    // Context line - both sides
                    let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                    hunk.leftLines.append(SplitLine(lineNumber: leftLineNum, content: content, type: .context))
                    hunk.rightLines.append(SplitLine(lineNumber: rightLineNum, content: content, type: .context))
                    leftLineNum += 1
                    rightLineNum += 1
                }
                currentHunk = hunk
            }
        }

        // Save last hunk
        if let hunk = currentHunk {
            hunks.append(hunk)
        }

        return hunks
    }

    private func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int) {
        // Parse @@ -1,3 +1,4 @@ format
        var oldStart = 1
        var newStart = 1

        if let oldRange = header.range(of: #"-(\d+)"#, options: .regularExpression) {
            let numStr = header[oldRange].dropFirst()
            oldStart = Int(numStr) ?? 1
        }
        if let newRange = header.range(of: #"\+(\d+)"#, options: .regularExpression) {
            let numStr = header[newRange].dropFirst()
            newStart = Int(numStr) ?? 1
        }

        return (oldStart, newStart)
    }
}

// MARK: - Models

private struct DiffHunk {
    let header: String
    var leftLines: [SplitLine]
    var rightLines: [SplitLine]
}

private struct SplitLine {
    let lineNumber: Int?
    let content: String
    let type: LineType

    enum LineType {
        case addition
        case deletion
        case context
        case empty
    }
}

// MARK: - Split Line View

private enum DiffSide {
    case left, right
}

private struct SplitDiffLineView: View {
    let line: SplitLine
    let side: DiffSide

    var body: some View {
        HStack(spacing: 0) {
            // Line number
            Text(lineNumberText)
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 6)

            // Content - no wrapping
            Text(line.content.isEmpty ? " " : line.content)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(minHeight: 22)
        .background(backgroundColor)
    }

    private var lineNumberText: String {
        if let num = line.lineNumber {
            return "\(num)"
        }
        return ""
    }

    private var backgroundColor: Color {
        switch line.type {
        case .addition:
            return Color.green.opacity(0.15)
        case .deletion:
            return Color.red.opacity(0.15)
        case .context, .empty:
            return Color.clear
        }
    }

    private var textColor: Color {
        switch line.type {
        case .addition:
            return .green
        case .deletion:
            return .red
        case .context:
            return .primary
        case .empty:
            return .clear
        }
    }
}
