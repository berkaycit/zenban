import SwiftUI

/// Fullscreen overlay view for dev server preview.
struct DevServerView: View {
    let card: Card
    let boardID: UUID?
    let setupCommand: String?
    let devCommand: String
    let onDismiss: () -> Void
    var onReconfigure: (() -> Void)?

    @Environment(DevServerManager.self) private var devServerManager
    @Environment(CmuxHostStore.self) private var cmuxHost
    @State private var startupTask: Task<Void, Never>?
    @State private var startupRequestID: UUID?

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
            handleServerStateChange(state)
        }
        .onDisappear {
            teardownPreview()
            cmuxHost.restoreTerminalFocus(for: card.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDevServer)) { _ in
            handleReload()
        }
        .onChange(of: state) { _, newState in
            handleServerStateChange(newState)
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
                .accessibilityLabel("Reconfigure dev server")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Preview")
            .accessibilityLabel("Close preview")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            browserPreview(url: url)

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
            .background(Color.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func outputLineView(_ line: OutputLine) -> some View {
        Text(line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(line.isError ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func browserPreview(url: URL) -> some View {
        if let context = cmuxHost.browserSurface(for: card.id) {
            BrowserPanelView(
                panel: context.panel,
                paneId: context.paneId,
                isFocused: true,
                isVisibleInUI: true,
                portalPriority: 1,
                onRequestPanelFocus: {
                    cmuxHost.focusBrowserSurface(for: card.id)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loadingView(message: "Preparing browser...")
                .overlay(alignment: .bottom) {
                    Text(url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.codeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 20)
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
            .background(Color.codeBackground)
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

    private func handleReload() {
        guard case .ready = devServerManager.state(for: card.id) else { return }
        startServer()
    }

    private func handleServerStateChange(_ state: DevServerManager.ServerState) {
        guard case .ready(let url) = state, let boardID else { return }
        cmuxHost.ensureBrowserSurface(for: card, boardID: boardID, url: url)
    }

    private func teardownPreview() {
        cancelStartupTask()
        devServerManager.stopServer(for: card.id)
    }

    private func cancelStartupTask() {
        startupTask?.cancel()
        startupTask = nil
        startupRequestID = nil
    }
}
