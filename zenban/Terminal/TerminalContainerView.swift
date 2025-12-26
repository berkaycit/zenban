import SwiftUI
import SwiftTerm
import AppKit

struct TerminalContainerView: NSViewRepresentable {
    let cardID: UUID
    var backgroundColor: SwiftUI.Color = SwiftUI.Color(red: 0.165, green: 0.165, blue: 0.153)
    @Environment(TerminalManager.self) private var terminalManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalHostView {
        let hostView = TerminalHostView()
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor(backgroundColor).cgColor

        context.coordinator.loadTask = Task { @MainActor in
            await loadTerminal(into: hostView, backgroundColor: backgroundColor)
        }

        return hostView
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        // Update background color
        nsView.layer?.backgroundColor = NSColor(backgroundColor).cgColor
        if let terminal = nsView.terminalView {
            terminal.frame = nsView.bounds
            terminal.nativeBackgroundColor = NSColor(backgroundColor)
        }

        // Update error state
        if let error = terminalManager.error {
            nsView.showError(error)
        } else {
            nsView.hideError()
        }

        // Update loading state
        if terminalManager.isLoading {
            nsView.showLoading()
        } else {
            nsView.hideLoading()
        }
    }

    static func dismantleNSView(_ nsView: TerminalHostView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
    }

    @MainActor
    private func loadTerminal(into hostView: TerminalHostView, backgroundColor: SwiftUI.Color) async {
        do {
            let view = try await terminalManager.terminalView(for: cardID)

            // Check if task was cancelled
            try Task.checkCancellation()

            view.frame = hostView.bounds
            view.autoresizingMask = [.width, .height]
            view.nativeBackgroundColor = NSColor(backgroundColor)

            hostView.subviews.forEach { $0.removeFromSuperview() }
            hostView.addSubview(view)
            hostView.terminalView = view
            hostView.hideError()
            hostView.hideLoading()
        } catch is CancellationError {
            // Task was cancelled, ignore
        } catch {
            hostView.showError(error.localizedDescription)
        }
    }

    final class Coordinator {
        var loadTask: Task<Void, Never>?
    }
}

final class TerminalHostView: NSView {
    var terminalView: LocalProcessTerminalView?
    private var errorLabel: NSTextField?
    private var loadingIndicator: NSProgressIndicator?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            terminalView?.frame = bounds
        }
    }

    override func layout() {
        super.layout()
        terminalView?.frame = bounds
        layoutErrorLabel()
        layoutLoadingIndicator()
    }

    func showError(_ message: String) {
        if errorLabel == nil {
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            addSubview(label)
            errorLabel = label
        }
        errorLabel?.stringValue = message
        errorLabel?.isHidden = false
        layoutErrorLabel()
    }

    func hideError() {
        errorLabel?.isHidden = true
    }

    func showLoading() {
        if loadingIndicator == nil {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            addSubview(indicator)
            loadingIndicator = indicator
        }
        loadingIndicator?.startAnimation(nil)
        loadingIndicator?.isHidden = false
        layoutLoadingIndicator()
    }

    func hideLoading() {
        loadingIndicator?.stopAnimation(nil)
        loadingIndicator?.isHidden = true
    }

    private func layoutErrorLabel() {
        guard let label = errorLabel, !label.isHidden else { return }
        let size = label.sizeThatFits(NSSize(width: bounds.width - 40, height: .greatestFiniteMagnitude))
        label.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func layoutLoadingIndicator() {
        guard let indicator = loadingIndicator, !indicator.isHidden else { return }
        let size: CGFloat = 20
        indicator.frame = NSRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
    }
}
