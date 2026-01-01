import SwiftUI
import GhosttySwift
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
        if let terminal = context.coordinator.terminalView {
            terminal.frame = nsView.bounds
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
            terminal.autoresizingMask = [.width, .height]

            hostView.subviews.forEach { $0.removeFromSuperview() }
            hostView.addSubview(terminal)
            coordinator.terminalView = terminal
        } catch is CancellationError {
            // Task was cancelled, ignore
        } catch {
            // Handle error silently
        }
    }

    final class Coordinator {
        var loadTask: Task<Void, Never>?
        var terminalView: GhosttyTerminalView?
    }
}
