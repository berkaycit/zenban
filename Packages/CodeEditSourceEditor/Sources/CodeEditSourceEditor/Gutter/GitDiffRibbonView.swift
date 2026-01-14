//
//  GitDiffRibbonView.swift
//  CodeEditSourceEditor
//
//  Git diff indicator ribbon view for the gutter
//

import Foundation
import AppKit
import CodeEditTextView

/// Displays git diff indicators as a ribbon on the left edge of the gutter
class GitDiffRibbonView: NSView {
    static let width: CGFloat = 4.0

    var gitDiffStatus: [Int: GitDiffLineStatus] = [:] {
        didSet {
            needsDisplay = true
        }
    }

    private var hoveredLineRange: ClosedRange<Int>? {
        didSet {
            if hoveredLineRange != oldValue {
                needsDisplay = true
            }
        }
    }

    private weak var textView: TextView?
    private weak var controller: TextViewController?
    private var trackingArea: NSTrackingArea?

    override public var isFlipped: Bool {
        true
    }

    init(controller: TextViewController) {
        self.controller = controller
        self.textView = controller.textView
        super.init(frame: .zero)

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = false

        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        setupTrackingArea()
    }

    override public func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredHunk(at: point)
    }

    override public func mouseExited(with event: NSEvent) {
        hoveredLineRange = nil
    }

    private func updateHoveredHunk(at point: NSPoint) {
        guard let textView = textView else { return }

        for linePosition in textView.layoutManager.linesStartingAt(0, until: frame.height) {
            let lineNumber = linePosition.index + 1
            guard let status = gitDiffStatus[lineNumber] else { continue }

            let barRect = CGRect(
                x: 0,
                y: linePosition.yPos,
                width: Self.width + 10,
                height: linePosition.height
            )

            if barRect.contains(point) {
                hoveredLineRange = findHunkRange(for: lineNumber, status: status)
                return
            }
        }

        hoveredLineRange = nil
    }

    private func findHunkRange(for lineNumber: Int, status: GitDiffLineStatus) -> ClosedRange<Int> {
        var start = lineNumber
        var end = lineNumber

        // Expand backwards
        while start > 1, let prevStatus = gitDiffStatus[start - 1] {
            if case .deleted = prevStatus { break }
            if case .deleted = status { break }
            if prevStatus == status {
                start -= 1
            } else {
                break
            }
        }

        // Expand forwards
        while let nextStatus = gitDiffStatus[end + 1] {
            if case .deleted = nextStatus { break }
            if case .deleted = status { break }
            if nextStatus == status {
                end += 1
            } else {
                break
            }
        }

        return start...end
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let textView = textView else {
            return
        }

        context.saveGState()

        // Draw highlight for hovered hunk first (behind bars)
        if let range = hoveredLineRange {
            context.setFillColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor)
            for lineNumber in range {
                guard let line = textView.layoutManager.textLineForIndex(lineNumber - 1) else { continue }
                // Highlight extends from gutter across entire visible width
                let highlightRect = CGRect(
                    x: -frame.minX, // Start from gutter's left edge
                    y: line.yPos,
                    width: textView.frame.width + frame.minX, // Extend to text view's right edge
                    height: line.height
                )
                context.fill(highlightRect)
            }
        }

        // Draw diff bars
        for linePosition in textView.layoutManager.linesStartingAt(dirtyRect.minY, until: dirtyRect.maxY) {
            let lineNumber = linePosition.index + 1
            guard let status = gitDiffStatus[lineNumber] else { continue }

            let isInHoveredRange = hoveredLineRange?.contains(lineNumber) ?? false

            let color: NSColor
            switch status {
            case .added:
                color = isInHoveredRange ? .systemGreen : NSColor.systemGreen.withAlphaComponent(0.7)
            case .modified:
                color = isInHoveredRange ? .systemOrange : NSColor.systemOrange.withAlphaComponent(0.7)
            case .deleted:
                let triangleColor = isInHoveredRange ? NSColor.systemRed : NSColor.systemRed.withAlphaComponent(0.7)
                context.setFillColor(triangleColor.cgColor)
                let markerSize: CGFloat = 6.0
                let xPos: CGFloat = 0
                let yPos = linePosition.yPos + (linePosition.height - markerSize) / 2

                context.beginPath()
                context.move(to: CGPoint(x: xPos, y: yPos))
                context.addLine(to: CGPoint(x: xPos + markerSize, y: yPos + markerSize / 2))
                context.addLine(to: CGPoint(x: xPos, y: yPos + markerSize))
                context.closePath()
                context.fillPath()
                continue
            }

            // Draw vertical bar
            context.setFillColor(color.cgColor)
            let barRect = CGRect(
                x: 0,
                y: linePosition.yPos,
                width: Self.width,
                height: linePosition.height
            )
            context.fill(barRect)
        }

        context.restoreGState()
    }
}
