import Foundation

// Parses diff lines on-demand for large diffs.
struct DiffLineParser {
    private let rawLines: [String]

    init(rawLines: [String]) {
        self.rawLines = rawLines
    }

    /// Parse a single line at the given index, calculating line numbers by scanning backwards.
    func parseLine(at rawIndex: Int) -> DiffLine {
        guard rawIndex < rawLines.count else {
            return DiffLine(lineNumber: 0, oldLineNumber: nil, newLineNumber: nil, content: "", type: .context)
        }

        let line = rawLines[rawIndex]
        let firstChar = line.first

        var oldNum = 0
        var newNum = 0

        for i in stride(from: rawIndex - 1, through: 0, by: -1) {
            let prevLine = rawLines[i]
            if prevLine.hasPrefix("@@") {
                if let (parsedOld, parsedNew) = parseHunkHeader(prevLine) {
                    oldNum = parsedOld
                    newNum = parsedNew
                }

                for j in (i + 1)..<rawIndex {
                    let scanLine = rawLines[j]
                    let scanChar = scanLine.first
                    if scanChar == "+" { newNum += 1 }
                    else if scanChar == "-" { oldNum += 1 }
                    else if scanChar == " " { oldNum += 1; newNum += 1 }
                }
                break
            }
        }

        if firstChar == "@" {
            return DiffLine(lineNumber: rawIndex, oldLineNumber: nil, newLineNumber: nil, content: line, type: .header)
        } else if firstChar == "+" {
            return DiffLine(lineNumber: rawIndex, oldLineNumber: nil, newLineNumber: String(newNum + 1), content: String(line.dropFirst()), type: .added)
        } else if firstChar == "-" {
            return DiffLine(lineNumber: rawIndex, oldLineNumber: String(oldNum + 1), newLineNumber: nil, content: String(line.dropFirst()), type: .deleted)
        } else {
            return DiffLine(lineNumber: rawIndex, oldLineNumber: String(oldNum + 1), newLineNumber: String(newNum + 1), content: String(line.dropFirst()), type: .context)
        }
    }

    /// Parse hunk header to extract starting line numbers.
    private func parseHunkHeader(_ line: String) -> (old: Int, new: Int)? {
        var oldNum = 0
        var newNum = 0

        if let minusRange = line.range(of: "-") {
            let afterMinus = line[minusRange.upperBound...]
            if let end = afterMinus.firstIndex(where: { $0 == "," || $0 == " " }),
               let num = Int(afterMinus[..<end]) {
                oldNum = num
            }
        }

        if let plusRange = line.range(of: " +") {
            let afterPlus = line[plusRange.upperBound...]
            if let end = afterPlus.firstIndex(where: { $0 == "," || $0 == " " }),
               let num = Int(afterPlus[..<end]) {
                newNum = num
            }
        }

        return (oldNum, newNum)
    }
}
