import SwiftUI
import AppKit

struct TerminalContainerView: NSViewRepresentable {
    let cardID: UUID
    let boardID: UUID
    let cardTitle: String
    @Environment(TerminalManager.self) private var terminalManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let hostView = NSView()
        hostView.wantsLayer = true
        let initialBackground = resolvedBackgroundColor(for: hostView.effectiveAppearance)
        hostView.layer?.backgroundColor = initialBackground.cgColor

        // Store references for hibernation in dismantleNSView
        context.coordinator.terminalManager = terminalManager
        context.coordinator.cardID = cardID

        context.coordinator.loadTask = Task { @MainActor in
            await loadTerminal(into: hostView, coordinator: context.coordinator)
        }

        return hostView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let resolvedBackgroundColor = resolvedBackgroundColor(for: nsView.effectiveAppearance)
        nsView.layer?.backgroundColor = resolvedBackgroundColor.cgColor
        if let scrollView = context.coordinator.scrollView {
            scrollView.frame = nsView.bounds
        }
        if let terminal = context.coordinator.terminalView {
            terminal.layer?.backgroundColor = resolvedBackgroundColor.cgColor
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil

        // Detach views from host but keep alive in TerminalManager
        nsView.subviews.forEach { $0.removeFromSuperview() }

        // Suspend terminal rendering (process stays alive)
        if let cardID = coordinator.cardID,
           let terminalManager = coordinator.terminalManager {
            terminalManager.suspendTerminal(for: cardID)
        }

        coordinator.terminalView = nil
        coordinator.scrollView = nil
    }

    @MainActor
    private func loadTerminal(into hostView: NSView, coordinator: Coordinator) async {
        do {
            let terminal = try await terminalManager.terminalView(for: cardID, boardID: boardID, cardTitle: cardTitle)

            try Task.checkCancellation()

            terminal.layer?.backgroundColor = resolvedBackgroundColor(for: hostView.effectiveAppearance).cgColor
            terminal.frame = hostView.bounds

            let scrollView: TerminalScrollView
            if let cachedScrollView = terminalManager.scrollView(for: cardID) {
                scrollView = cachedScrollView
                scrollView.frame = hostView.bounds
                scrollView.autoresizingMask = [.width, .height]
            } else {
                let hasScrollStateToRestore = terminalManager.cachedScrollState(for: cardID) != nil
                let newScrollView = TerminalScrollView(
                    contentSize: hostView.bounds.size,
                    surfaceView: terminal,
                    hasScrollStateToRestore: hasScrollStateToRestore
                )
                newScrollView.frame = hostView.bounds
                newScrollView.autoresizingMask = [.width, .height]
                terminalManager.setScrollView(newScrollView, for: cardID)
                scrollView = newScrollView
            }

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
        weak var terminalManager: TerminalManager?
        var cardID: UUID?
    }

    private func resolvedBackgroundColor(for appearance: NSAppearance?) -> NSColor {
        let colorScheme = GhosttyConfig.currentColorSchemePreference(appAppearance: appearance)
        let config = GhosttyConfig.load(preferredColorScheme: colorScheme)
        return config.backgroundColor.withAlphaComponent(config.backgroundOpacity)
    }
}
