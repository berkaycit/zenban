import SwiftUI
import WebKit

/// Fullscreen overlay view for dev server preview.
struct DevServerView: View {
    let card: Card
    let setupCommand: String?
    let devCommand: String
    let autoOpenConsole: Bool
    let onDismiss: () -> Void
    var onReconfigure: (() -> Void)?

    @Environment(DevServerManager.self) private var devServerManager
    @State private var browserPanel: BrowserPanel?
    @State private var browserIsFocused = true
    @State private var consoleOpenTask: Task<Void, Never>?
    @State private var startupTask: Task<Void, Never>?
    @State private var startupRequestID: UUID?
    @State private var autoOpenedConsolePanelID: UUID?

    var body: some View {
        let state = devServerManager.state(for: card.id)

        VStack(spacing: 0) {
            headerSection(state: state)
            Divider()
            contentSection(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBackground)
        .compositingGroup()
        .onAppear {
            startServer()
        }
        .onDisappear {
            teardownPreview()
        }
        .onChange(of: state) { _, newState in
            handleStateChange(newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDevServer)) { _ in
            handleReload()
        }
    }

    // MARK: - Header

    private func headerSection(state: DevServerManager.ServerState) -> some View {
        HStack(spacing: 12) {
            if case .ready(let url) = state {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else {
                Text("Dev Server")
                    .font(.headline)
            }

            Spacer()

            if let onReconfigure {
                Button(action: onReconfigure) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reconfigure")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Preview")
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private func contentSection(state: DevServerManager.ServerState) -> some View {
        switch state {
        case .idle:
            loadingView(message: "Initializing...")

        case .runningSetup:
            outputView(title: "Installing dependencies...", showSpinner: true)

        case .startingServer:
            outputView(title: "Starting dev server...", showSpinner: true)

        case .detectingPort:
            outputView(title: "Waiting for server...", showSpinner: true)

        case .ready(let url):
            browserSection(url: url)

        case .error(let message):
            errorView(message: message)
        }
    }

    private func loadingView(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func outputView(title: String, showSpinner: Bool) -> some View {
        let _ = devServerManager.outputVersion[card.id]
        let lines = devServerManager.outputLinesArray(for: card.id)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if showSpinner {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if lines.isEmpty {
                            Text("Waiting for output...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(lines) { line in
                                outputLineView(line)
                            }
                        }
                    }
                    .padding(12)
                    .id("output-bottom")
                    .onChange(of: devServerManager.outputVersion[card.id]) {
                        proxy.scrollTo("output-bottom", anchor: .bottom)
                    }
                }
            }
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func outputLineView(_ line: OutputLine) -> some View {
        Text(line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(line.isError ? Color.red : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func browserSection(url: URL) -> some View {
        if let browserPanel {
            BrowserPanelView(
                panel: browserPanel,
                isFocused: browserIsFocused,
                isVisibleInUI: true,
                portalPriority: 1,
                onRequestPanelFocus: {
                    browserIsFocused = true
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                prepareBrowserPanel(for: url)
                scheduleConsoleOpenIfNeeded(for: browserPanel)
            }
        } else {
            loadingView(message: "Preparing preview...")
                .onAppear {
                    prepareBrowserPanel(for: url)
                }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text("Server Error")
                .font(.headline)

            ScrollView {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 200)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 32)

            retryReconfigureButtons(onRetry: startServer)

            Button("Close") {
                onDismiss()
            }
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Components

    private func retryReconfigureButtons(onRetry: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button("Retry", action: onRetry)

            if let reconfigure = onReconfigure {
                Button("Reconfigure", action: reconfigure)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Actions

    private func startServer() {
        cancelStartupTask()
        resetBrowserPreview()
        guard let worktreePath = card.worktreePath else { return }

        let requestID = devServerManager.beginRequest(for: card.id)
        startupRequestID = requestID
        let task = Task { @MainActor in
            await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    guard startupRequestID == requestID else { return }

                    let needsSetup = PackageJsonParser.isSetupNeeded(in: worktreePath)
                    if needsSetup, let setup = setupCommand {
                        try await devServerManager.runSetup(
                            for: card.id,
                            command: setup,
                            directory: worktreePath,
                            requestID: requestID
                        )
                    }

                    try Task.checkCancellation()
                    guard startupRequestID == requestID else { return }

                    _ = try await devServerManager.startDevServer(
                        for: card.id,
                        command: devCommand,
                        directory: worktreePath,
                        requestID: requestID
                    )
                } catch is CancellationError {
                    // Cancellation is expected when the preview closes or restarts.
                } catch {
                    // DevServerManager drives the visible state.
                }

                if startupRequestID == requestID {
                    startupTask = nil
                    startupRequestID = nil
                }
            } onCancel: {
                Task { @MainActor in
                    devServerManager.stopRequest(for: card.id, requestID: requestID)
                }
            }
        }
        startupTask = task
    }

    private func handleStateChange(_ state: DevServerManager.ServerState) {
        switch state {
        case .ready(let url):
            prepareBrowserPanel(for: url)
        case .idle:
            cancelConsoleOpenTask()
        case .runningSetup, .startingServer, .detectingPort, .error:
            browserIsFocused = true
            cancelConsoleOpenTask()
        }
    }

    private func handleReload() {
        guard case .ready = devServerManager.state(for: card.id),
              let browserPanel else { return }
        browserIsFocused = true
        browserPanel.reload()
    }

    private func prepareBrowserPanel(for url: URL) {
        browserIsFocused = true

        if let browserPanel {
            if browserPanel.currentURL != url {
                browserPanel.navigate(to: url)
            }
            scheduleConsoleOpenIfNeeded(for: browserPanel)
            return
        }

        let panel = BrowserPanel(workspaceId: card.id, initialURL: url)
        browserPanel = panel
        autoOpenedConsolePanelID = nil
    }

    private func scheduleConsoleOpenIfNeeded(for panel: BrowserPanel) {
        guard autoOpenConsole else { return }
        guard autoOpenedConsolePanelID != panel.id else { return }

        autoOpenedConsolePanelID = panel.id
        cancelConsoleOpenTask()
        consoleOpenTask = Task { @MainActor in
            for _ in 0..<80 {
                guard browserPanel?.id == panel.id else { return }

                guard isPreviewReadyForConsole(panel) else {
                    try? await Task.sleep(nanoseconds: 75_000_000)
                    continue
                }

                panel.requestDeveloperToolsConsoleAfterAttach()
                panel.focus()

                for delay in [75_000_000 as UInt64, 200_000_000] {
                    try? await Task.sleep(nanoseconds: delay)
                    guard browserPanel?.id == panel.id else { return }
                    panel.focus()
                }

                return
            }

            autoOpenedConsolePanelID = nil
        }
    }

    private func isPreviewReadyForConsole(_ panel: BrowserPanel) -> Bool {
        guard panel.webView.window != nil else { return false }
        guard !panel.webView.isHiddenOrHasHiddenAncestor else { return false }
        guard !panel.isLoading, !panel.webView.isLoading else { return false }

        let loadedURL = panel.webView.url ?? panel.currentURL
        guard let loadedURL else { return false }
        return loadedURL.absoluteString != "about:blank"
    }

    private func cancelConsoleOpenTask() {
        consoleOpenTask?.cancel()
        consoleOpenTask = nil
    }

    private func resetBrowserPreview() {
        cancelConsoleOpenTask()
        browserPanel?.close()
        browserPanel = nil
        autoOpenedConsolePanelID = nil
        browserIsFocused = true
    }

    private func teardownPreview() {
        cancelStartupTask()
        cancelConsoleOpenTask()
        browserPanel?.close()
        browserPanel = nil
        devServerManager.stopServer(for: card.id)
    }

    private func cancelStartupTask() {
        startupTask?.cancel()
        startupTask = nil
        startupRequestID = nil
    }
}
