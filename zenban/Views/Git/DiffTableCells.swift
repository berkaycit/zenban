import AppKit

class DiffNSRowView: NSTableRowView {
    var lineType: DiffLineType? {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let type = lineType else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.8).setFill()
            bounds.fill()
            return
        }
        type.nsBackgroundColor.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }
}

class FileHeaderCellView: NSTableCellView {
    private let pathLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pathLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            pathLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    func configure(path: String, fontSize: Double, fontFamily: String) {
        pathLabel.stringValue = path
        pathLabel.font = NSFont(name: fontFamily, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    }
}

class LineCellView: NSTableCellView {
    private let oldNumLabel = NSTextField(labelWithString: "")
    private let newNumLabel = NSTextField(labelWithString: "")
    private let markerLabel = NSTextField(labelWithString: "")
    private let contentLabel = NSTextField(labelWithString: "")
    private let lineNumBg = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        lineNumBg.wantsLayer = true
        updateGutterBackground()
        lineNumBg.translatesAutoresizingMaskIntoConstraints = false

        [oldNumLabel, newNumLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.alignment = .right
            $0.textColor = .tertiaryLabelColor
        }

        markerLabel.translatesAutoresizingMaskIntoConstraints = false
        markerLabel.alignment = .center

        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.lineBreakMode = .byWordWrapping
        contentLabel.maximumNumberOfLines = 0
        contentLabel.isSelectable = true
        contentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(lineNumBg)
        addSubview(oldNumLabel)
        addSubview(newNumLabel)
        addSubview(markerLabel)
        addSubview(contentLabel)

        NSLayoutConstraint.activate([
            lineNumBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            lineNumBg.topAnchor.constraint(equalTo: topAnchor),
            lineNumBg.bottomAnchor.constraint(equalTo: bottomAnchor),
            lineNumBg.widthAnchor.constraint(equalToConstant: 56),

            oldNumLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            oldNumLabel.widthAnchor.constraint(equalToConstant: 20),
            oldNumLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            newNumLabel.leadingAnchor.constraint(equalTo: oldNumLabel.trailingAnchor, constant: 2),
            newNumLabel.widthAnchor.constraint(equalToConstant: 20),
            newNumLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            markerLabel.leadingAnchor.constraint(equalTo: lineNumBg.trailingAnchor, constant: 4),
            markerLabel.widthAnchor.constraint(equalToConstant: 16),
            markerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            contentLabel.leadingAnchor.constraint(equalTo: markerLabel.trailingAnchor, constant: 4),
            contentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            contentLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGutterBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGutterBackground()
    }

    private func updateGutterBackground() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark
            ? NSColor.white.withAlphaComponent(0.04)
            : NSColor.black.withAlphaComponent(0.03)
        lineNumBg.layer?.backgroundColor = bgColor.cgColor
    }

    func configure(diffLine: DiffLine, fontSize: Double, fontFamily: String) {
        let font = NSFont(name: fontFamily, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let smallFont = NSFont(name: fontFamily, size: fontSize - 1) ?? NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)

        oldNumLabel.stringValue = diffLine.oldLineNumber ?? ""
        oldNumLabel.font = smallFont
        oldNumLabel.alphaValue = diffLine.oldLineNumber != nil ? 1 : 0

        newNumLabel.stringValue = diffLine.newLineNumber ?? ""
        newNumLabel.font = smallFont
        newNumLabel.alphaValue = diffLine.newLineNumber != nil ? 1 : 0

        markerLabel.stringValue = diffLine.type.marker
        markerLabel.font = font
        markerLabel.textColor = diffLine.type.nsMarkerColor

        contentLabel.stringValue = diffLine.content.isEmpty ? " " : diffLine.content
        contentLabel.font = font
    }
}
