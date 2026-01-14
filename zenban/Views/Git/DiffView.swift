import SwiftUI
import AppKit

struct DiffView: NSViewRepresentable {
    private let diffOutput: String?
    private let preloadedLines: [DiffLine]?

    let fontSize: Double
    let fontFamily: String
    let showFileHeaders: Bool
    let scrollToFile: String?
    let onFileVisible: ((String) -> Void)?
    let onOpenFile: ((String) -> Void)?

    init(
        diffOutput: String,
        fontSize: Double = 12,
        fontFamily: String = "Menlo",
        showFileHeaders: Bool = true,
        scrollToFile: String? = nil,
        onFileVisible: ((String) -> Void)? = nil,
        onOpenFile: ((String) -> Void)? = nil
    ) {
        self.diffOutput = diffOutput
        self.preloadedLines = nil
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.showFileHeaders = showFileHeaders
        self.scrollToFile = scrollToFile
        self.onFileVisible = onFileVisible
        self.onOpenFile = onOpenFile
    }

    init(
        lines: [DiffLine],
        fontSize: Double = 12,
        fontFamily: String = "Menlo",
        showFileHeaders: Bool = false
    ) {
        self.diffOutput = nil
        self.preloadedLines = lines
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.showFileHeaders = showFileHeaders
        self.scrollToFile = nil
        self.onFileVisible = nil
        self.onOpenFile = nil
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = CopyableTableView()
        tableView.copyProvider = context.coordinator

        tableView.style = .plain
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsColumnSelection = false
        tableView.usesAutomaticRowHeights = true
        tableView.gridStyleMask = []
        tableView.gridColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        context.coordinator.tableView = tableView
        context.coordinator.showFileHeaders = showFileHeaders
        context.coordinator.onFileVisible = onFileVisible
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.setupScrollObserver(for: scrollView)

        if let lines = preloadedLines {
            context.coordinator.loadLines(lines, fontSize: fontSize, fontFamily: fontFamily)
        } else if let output = diffOutput {
            context.coordinator.parseAndReload(diffOutput: output, fontSize: fontSize, fontFamily: fontFamily)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.showFileHeaders = showFileHeaders
        context.coordinator.onFileVisible = onFileVisible
        context.coordinator.onOpenFile = onOpenFile

        if let lines = preloadedLines {
            context.coordinator.loadLines(lines, fontSize: fontSize, fontFamily: fontFamily)
        } else if let output = diffOutput {
            context.coordinator.parseAndReload(diffOutput: output, fontSize: fontSize, fontFamily: fontFamily)
        }

        if let file = scrollToFile, file != context.coordinator.lastScrolledFile {
            context.coordinator.scrollToFile(file)
            context.coordinator.lastScrolledFile = file
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(showFileHeaders: showFileHeaders, onOpenFile: onOpenFile)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, CopyableTableViewProvider {
        weak var tableView: NSTableView?
        var rows: [DiffRow] = []
        var rowHeight: CGFloat = 20
        var fontSize: Double = 12
        var fontFamily: String = "Menlo"
        var showFileHeaders: Bool = true
        var onFileVisible: ((String) -> Void)?
        var onOpenFile: ((String) -> Void)?
        var lastScrolledFile: String?

        private var lastDataHash: Int = 0
        private var parseTask: Task<ParsedDiffMetadata, Never>?
        private var fileRowIndices: [String: Int] = [:]
        private var rowToFilePath: [Int: String] = [:]
        private var lastVisibleFile: String?
        private var scrollObserver: NSObjectProtocol?

        enum DiffRow {
            case fileHeader(path: String)
            case line(DiffLine)
        }

        private enum RowKind: Sendable {
            case fileHeader(path: String)
            case line(DiffLine)
        }

        private struct ParsedDiffMetadata: Sendable {
            let rowKinds: [RowKind]
            let fileRowIndices: [String: Int]
            let rowToFilePath: [Int: String]
        }

        init(showFileHeaders: Bool, onOpenFile: ((String) -> Void)? = nil) {
            self.showFileHeaders = showFileHeaders
            self.onOpenFile = onOpenFile
            super.init()
        }

        deinit {
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            parseTask?.cancel()
        }

        func setupScrollObserver(for scrollView: NSScrollView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.updateVisibleFile()
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
        }

        private func updateVisibleFile() {
            guard let tableView = tableView else { return }
            let visibleRect = tableView.visibleRect

            let firstVisibleRow = max(0, tableView.row(at: NSPoint(x: 0, y: visibleRect.minY + 1)))
            guard firstVisibleRow >= 0, firstVisibleRow < rows.count else { return }

            var file = rowToFilePath[firstVisibleRow]

            if file == nil {
                let lastVisibleRow = min(rows.count - 1, max(firstVisibleRow, tableView.row(at: NSPoint(x: 0, y: visibleRect.maxY - 1))))
                if lastVisibleRow >= firstVisibleRow {
                    for row in firstVisibleRow...lastVisibleRow {
                        if let path = rowToFilePath[row] {
                            file = path
                            break
                        }
                    }
                }
            }

            if file == nil, firstVisibleRow > 0 {
                for row in stride(from: firstVisibleRow - 1, through: 0, by: -1) {
                    if let path = rowToFilePath[row] {
                        file = path
                        break
                    }
                }
            }

            if let file, file != lastVisibleFile {
                lastVisibleFile = file
                onFileVisible?(file)
            }
        }

        func scrollToFile(_ file: String) {
            guard let tableView = tableView,
                  let rowIndex = fileRowIndices[file] else { return }

            tableView.scrollRowToVisible(rowIndex)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let rowRect = tableView.rect(ofRow: rowIndex)
                tableView.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: rowRect.minY))
            }
        }

        func loadLines(_ lines: [DiffLine], fontSize: Double, fontFamily: String) {
            let newHash = lines.hashValue ^ fontSize.hashValue ^ fontFamily.hashValue
            guard newHash != lastDataHash else { return }

            lastDataHash = newHash
            self.fontSize = fontSize
            self.fontFamily = fontFamily

            let font = NSFont(name: fontFamily, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            rowHeight = ceil(font.ascender - font.descender + font.leading) + 6

            rows = lines.map { .line($0) }
            tableView?.reloadData()
        }

        func parseAndReload(diffOutput: String, fontSize: Double, fontFamily: String) {
            let newHash = diffOutput.hashValue ^ fontSize.hashValue ^ fontFamily.hashValue
            guard newHash != lastDataHash else { return }

            lastDataHash = newHash
            self.fontSize = fontSize
            self.fontFamily = fontFamily

            let font = NSFont(name: fontFamily, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            rowHeight = ceil(font.ascender - font.descender + font.leading) + 6

            parseTask?.cancel()
            let showFileHeaders = self.showFileHeaders

            let task = Task.detached(priority: .utility) {
                Self.parseDiffOutput(diffOutput: diffOutput, showFileHeaders: showFileHeaders)
            }
            parseTask = task

            Task { @MainActor [weak self] in
                guard let self else { return }
                let parsed = await task.value
                guard !Task.isCancelled, self.lastDataHash == newHash else { return }

                self.fileRowIndices = parsed.fileRowIndices
                self.rowToFilePath = parsed.rowToFilePath
                self.rows = parsed.rowKinds.map { kind in
                    switch kind {
                    case .fileHeader(let path):
                        return .fileHeader(path: path)
                    case .line(let diffLine):
                        return .line(diffLine)
                    }
                }

                self.tableView?.reloadData()
            }
        }

        nonisolated private static func parseDiffOutput(
            diffOutput: String,
            showFileHeaders: Bool
        ) -> ParsedDiffMetadata {
            let maxLines = 200_000
            var rowKinds: [RowKind] = []
            rowKinds.reserveCapacity(max(256, diffOutput.count / 48))

            var fileRowIndices: [String: Int] = [:]
            var rowToFilePath: [Int: String] = [:]
            var rowIndex = 0
            var currentFilePath: String?

            var oldLineNum = 0
            var newLineNum = 0
            var lineCounter = 0

            diffOutput.enumerateLines { line, stop in
                if lineCounter >= maxLines {
                    let truncatedLine = DiffLine(
                        lineNumber: rowIndex,
                        oldLineNumber: nil,
                        newLineNumber: nil,
                        content: "... diff view truncated (too many lines) ...",
                        type: .header
                    )
                    rowKinds.append(.line(truncatedLine))
                    stop = true
                    return
                }
                lineCounter += 1

                if line.hasPrefix("diff --git ") {
                    currentFilePath = DiffParser.parseFilePathFromDiffHeader(line)
                    oldLineNum = 0
                    newLineNum = 0
                    if showFileHeaders, let path = currentFilePath, !path.isEmpty {
                        fileRowIndices[path] = rowIndex
                        rowKinds.append(.fileHeader(path: path))
                        rowToFilePath[rowIndex] = path
                        rowIndex += 1
                    }
                    return
                }

                if line.hasPrefix("--- ") ||
                    line.hasPrefix("+++ ") ||
                    line.hasPrefix("index ") ||
                    line.hasPrefix("new file") ||
                    line.hasPrefix("deleted file") ||
                    line.hasPrefix("similarity index") ||
                    line.hasPrefix("rename from") ||
                    line.hasPrefix("rename to") {
                    return
                }

                if line.hasPrefix("@@") {
                    for component in line.split(separator: " ") {
                        if component.hasPrefix("-") && !component.hasPrefix("---") {
                            let rangeStr = component.dropFirst()
                            if let numPart = rangeStr.split(separator: ",").first,
                               let start = Int(numPart) {
                                oldLineNum = start - 1
                            }
                        } else if component.hasPrefix("+") && !component.hasPrefix("+++") {
                            let rangeStr = component.dropFirst()
                            if let numPart = rangeStr.split(separator: ",").first,
                               let start = Int(numPart) {
                                newLineNum = start - 1
                            }
                        }
                    }

                    let diffLine = DiffLine(
                        lineNumber: rowIndex,
                        oldLineNumber: nil,
                        newLineNumber: nil,
                        content: line,
                        type: .header
                    )
                    rowKinds.append(.line(diffLine))
                    if let path = currentFilePath {
                        rowToFilePath[rowIndex] = path
                    }
                    rowIndex += 1
                    return
                }

                if line.hasPrefix("+") {
                    newLineNum += 1
                    let diffLine = DiffLine(
                        lineNumber: rowIndex,
                        oldLineNumber: nil,
                        newLineNumber: String(newLineNum),
                        content: String(line.dropFirst()),
                        type: .added
                    )
                    rowKinds.append(.line(diffLine))
                    if let path = currentFilePath {
                        rowToFilePath[rowIndex] = path
                    }
                    rowIndex += 1
                    return
                }

                if line.hasPrefix("-") {
                    oldLineNum += 1
                    let diffLine = DiffLine(
                        lineNumber: rowIndex,
                        oldLineNumber: String(oldLineNum),
                        newLineNumber: nil,
                        content: String(line.dropFirst()),
                        type: .deleted
                    )
                    rowKinds.append(.line(diffLine))
                    if let path = currentFilePath {
                        rowToFilePath[rowIndex] = path
                    }
                    rowIndex += 1
                    return
                }

                if line.hasPrefix(" ") {
                    oldLineNum += 1
                    newLineNum += 1
                    let diffLine = DiffLine(
                        lineNumber: rowIndex,
                        oldLineNumber: String(oldLineNum),
                        newLineNumber: String(newLineNum),
                        content: String(line.dropFirst()),
                        type: .context
                    )
                    rowKinds.append(.line(diffLine))
                    if let path = currentFilePath {
                        rowToFilePath[rowIndex] = path
                    }
                    rowIndex += 1
                }
            }

            return ParsedDiffMetadata(
                rowKinds: rowKinds,
                fileRowIndices: fileRowIndices,
                rowToFilePath: rowToFilePath
            )
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count else { return nil }

            switch rows[row] {
            case .fileHeader(let path):
                return makeFileHeaderCell(path: path, tableView: tableView)
            case .line(let diffLine):
                return makeLineCell(diffLine: diffLine, tableView: tableView)
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row < rows.count else { return nil }
            let rowView = DiffNSRowView()

            switch rows[row] {
            case .fileHeader:
                rowView.lineType = nil
            case .line(let diffLine):
                rowView.lineType = diffLine.type
            }

            return rowView
        }

        private func makeFileHeaderCell(path: String, tableView: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("FileHeader")
            if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileHeaderCellView {
                cell.configure(path: path, fontSize: fontSize, fontFamily: fontFamily)
                return cell
            }
            let cell = FileHeaderCellView(identifier: id)
            cell.configure(path: path, fontSize: fontSize, fontFamily: fontFamily)
            return cell
        }

        private func makeLineCell(diffLine: DiffLine, tableView: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("DiffLine")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? LineCellView
                ?? LineCellView(identifier: id)
            cell.configure(diffLine: diffLine, fontSize: fontSize, fontFamily: fontFamily)
            return cell
        }

        func selectedCopyText() -> String {
            guard let tableView = tableView else { return "" }
            var lines: [String] = []
            for rowIndex in tableView.selectedRowIndexes where rowIndex < rows.count {
                switch rows[rowIndex] {
                case .fileHeader(let path):
                    lines.append("--- \(path) ---")
                case .line(let diffLine):
                    lines.append("\(diffLine.type.marker)\(diffLine.content)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }
}
