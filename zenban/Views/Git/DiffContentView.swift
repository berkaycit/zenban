import SwiftUI

struct DiffContentView: View {
    let diffText: String

    private static let lineLimit = 300

    @State private var allRows: [DiffRow] = []
    @State private var parseTask: Task<Void, Never>?
    @State private var showAllLines = false

    private var visibleRows: [DiffRow] {
        if showAllLines || allRows.count <= Self.lineLimit {
            return allRows
        }
        return Array(allRows.prefix(Self.lineLimit))
    }

    private var hiddenLineCount: Int {
        max(0, allRows.count - Self.lineLimit)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(visibleRows) { row in
                DiffRowView(row: row)
            }

            if !showAllLines && hiddenLineCount > 0 {
                Button {
                    showAllLines = true
                } label: {
                    Text("Show \(hiddenLineCount) more lines...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .background(Color.secondary.opacity(0.03))
        .onAppear {
            startParsing()
        }
        .onDisappear {
            parseTask?.cancel()
        }
        .onChange(of: diffText) { _, _ in
            showAllLines = false
            startParsing()
        }
    }

    private func startParsing() {
        parseTask?.cancel()
        parseTask = Task.detached(priority: .userInitiated) {
            let result = Self.parseDiff(diffText)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                allRows = result
            }
        }
    }

    // MARK: - Parsing

    private static func parseDiff(_ text: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var rowId = 0
        var leftLineNum = 0
        var rightLineNum = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("@@") {
                let (oldStart, newStart) = parseHunkHeader(line)
                leftLineNum = oldStart
                rightLineNum = newStart
                rows.append(DiffRow(id: rowId, type: .header(line)))
                rowId += 1
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") ||
                      line.hasPrefix("---") || line.hasPrefix("+++") {
                continue
            } else if line.hasPrefix("+") {
                let content = String(line.dropFirst())
                rows.append(DiffRow(
                    id: rowId,
                    type: .line(
                        left: DiffCell(lineNumber: nil, content: "", cellType: .empty),
                        right: DiffCell(lineNumber: rightLineNum, content: content, cellType: .addition)
                    )
                ))
                rightLineNum += 1
                rowId += 1
            } else if line.hasPrefix("-") {
                let content = String(line.dropFirst())
                rows.append(DiffRow(
                    id: rowId,
                    type: .line(
                        left: DiffCell(lineNumber: leftLineNum, content: content, cellType: .deletion),
                        right: DiffCell(lineNumber: nil, content: "", cellType: .empty)
                    )
                ))
                leftLineNum += 1
                rowId += 1
            } else if leftLineNum > 0 || rightLineNum > 0 {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                rows.append(DiffRow(
                    id: rowId,
                    type: .line(
                        left: DiffCell(lineNumber: leftLineNum, content: content, cellType: .context),
                        right: DiffCell(lineNumber: rightLineNum, content: content, cellType: .context)
                    )
                ))
                leftLineNum += 1
                rightLineNum += 1
                rowId += 1
            }
        }

        return rows
    }

    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int) {
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

private struct DiffRow: Identifiable {
    let id: Int
    let type: RowType

    enum RowType {
        case header(String)
        case line(left: DiffCell, right: DiffCell)
    }
}

private struct DiffCell {
    let lineNumber: Int?
    let content: String
    let cellType: CellType

    enum CellType {
        case addition
        case deletion
        case context
        case empty
    }
}

// MARK: - Row View

private struct DiffRowView: View {
    let row: DiffRow

    var body: some View {
        switch row.type {
        case .header(let text):
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))

        case .line(let left, let right):
            HStack(spacing: 0) {
                DiffCellView(cell: left)
                Divider()
                DiffCellView(cell: right)
            }
        }
    }
}

private struct DiffCellView: View {
    let cell: DiffCell

    var body: some View {
        HStack(spacing: 0) {
            Text(cell.lineNumber.map { "\($0)" } ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 6)

            Text(cell.content.isEmpty ? " " : cell.content)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 22)
        .background(backgroundColor)
    }

    private var backgroundColor: Color {
        switch cell.cellType {
        case .addition: return Color.green.opacity(0.15)
        case .deletion: return Color.red.opacity(0.15)
        case .context, .empty: return Color.clear
        }
    }

    private var textColor: Color {
        switch cell.cellType {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .primary
        case .empty: return .clear
        }
    }
}
