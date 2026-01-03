import SwiftUI
import AppKit

struct TerminalContainerView: NSViewRepresentable {
    let cardID: UUID
    let boardID: UUID
    let cardTitle: String
    var backgroundColor: SwiftUI.Color = SwiftUI.Color(red: 0.1, green: 0.1, blue: 0.12)
    @Environment(TerminalManager.self) private var terminalManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let hostView = NSView()
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor(backgroundColor).cgColor

        context.coordinator.loadTask = Task { @MainActor in
            await loadTerminal(into: hostView, coordinator: context.coordinator, backgroundColor: backgroundColor)
        }

        return hostView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = NSColor(backgroundColor).cgColor
        if let scrollView = context.coordinator.scrollView {
            scrollView.frame = nsView.bounds
        }
        if let terminal = context.coordinator.terminalView {
            terminal.layer?.backgroundColor = NSColor(backgroundColor).cgColor
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
    }

    @MainActor
    private func loadTerminal(into hostView: NSView, coordinator: Coordinator, backgroundColor: SwiftUI.Color) async {
        do {
            let terminal = try await terminalManager.terminalView(for: cardID, boardID: boardID, cardTitle: cardTitle)

            try Task.checkCancellation()

            terminal.layer?.backgroundColor = NSColor(backgroundColor).cgColor
            terminal.frame = hostView.bounds

            let scrollView = TerminalScrollView(contentSize: hostView.bounds.size, surfaceView: terminal)
            scrollView.frame = hostView.bounds
            scrollView.autoresizingMask = [.width, .height]

            hostView.subviews.forEach { $0.removeFromSuperview() }
            hostView.addSubview(scrollView)
            coordinator.terminalView = terminal
            coordinator.scrollView = scrollView
        } catch is CancellationError {
            // Task was cancelled, ignore
        } catch {
            // Handle error silently
        }
    }

    final class Coordinator {
        var loadTask: Task<Void, Never>?
        var terminalView: GhosttyTerminalView?
        var scrollView: TerminalScrollView?
    }
}
