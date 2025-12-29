import SwiftUI

/// Fullscreen overlay view for dev server preview
struct DevServerView: View {
    let card: Card
    let setupCommand: String?
    let devCommand: String
    let onDismiss: () -> Void
    var onReconfigure: (() -> Void)?

    @Environment(DevServerManager.self) private var devServerManager
    @State private var serverURL: URL?
    @State private var isWebViewLoading = true
    @State private var reloadTrigger = 0
    @State private var webViewError: String?
    @State private var retryCount = 0
    @State private var showConsole = true

    private let maxRetries = 5
    private let consoleHeight: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            contentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBackground)
        .compositingGroup()
        .onAppear {
            startServer()
        }
        .onDisappear {
            devServerManager.stopServer(for: card.id)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)

            if let url = serverURL {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else {
                Text("Dev Server")
                    .font(.headline)
            }

            Spacer()

            if serverURL != nil {
                if isWebViewLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: { reloadTrigger += 1 }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isWebViewLoading)

                Button(action: { withAnimation(.easeOut(duration: 0.15)) { showConsole.toggle() } }) {
                    Image(systemName: "terminal")
                        .foregroundStyle(showConsole ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle Console")
            }
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        let state = devServerManager.state(for: card.id)

        switch state {
        case .idle:
            loadingView(message: "Initializing...")

        case .runningSetup(let output):
            outputView(title: "Installing dependencies...", output: output, showSpinner: true)

        case .startingServer(let output):
            outputView(title: "Starting dev server...", output: output, showSpinner: true)

        case .detectingPort(let output):
            outputView(title: "Waiting for server...", output: output, showSpinner: true)

        case .ready(let url):
            webViewSection(url: url)

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

    private func outputView(title: String, output: String, showSpinner: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    Text(output.isEmpty ? "Waiting for output..." : output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(output.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("output-bottom")
                        .onChange(of: output) {
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

    @ViewBuilder
    private func webViewSection(url: URL) -> some View {
        VStack(spacing: 0) {
            ZStack {
                ReloadableWebView(
                    url: url,
                    isLoading: $isWebViewLoading,
                    reloadTrigger: $reloadTrigger,
                    onError: { error in
                        handleWebViewError(error)
                    }
                )

                if let error = webViewError {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Connection Error")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if retryCount < maxRetries {
                            Text("Retrying... (\(retryCount + 1)/\(maxRetries))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            retryReconfigureButtons {
                                retryCount = 0
                                webViewError = nil
                                reloadTrigger += 1
                            }
                        }
                    }
                    .padding(32)
                    .background(Color.cardBackground.opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showConsole {
                Divider()
                consoleSection
            }
        }
        .onAppear {
            serverURL = url
        }
    }

    private var consoleSection: some View {
        VStack(spacing: 0) {
            consoleHeader
            consoleContent
        }
        .frame(height: consoleHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private var consoleHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Console")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: { withAnimation(.easeOut(duration: 0.15)) { showConsole = false } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }

    private var consoleContent: some View {
        // Observe version for throttled updates
        let _ = devServerManager.outputVersion[card.id]
        let output = devServerManager.output(for: card.id)
        let displayText = limitedConsoleOutput(output)

        return ScrollView {
            ScrollViewReader { proxy in
                Text(displayText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .id("console-bottom")
                    .onAppear {
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                    .onChange(of: devServerManager.outputVersion[card.id]) {
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func limitedConsoleOutput(_ output: String) -> String {
        guard !output.isEmpty else { return "Waiting for output..." }

        let maxLines = 300

        // Scan from end to find maxLines newlines - O(k) instead of O(n)
        var newlineCount = 0
        var cutIndex = output.endIndex

        for i in output.indices.reversed() {
            if output[i] == "\n" {
                newlineCount += 1
                if newlineCount >= maxLines {
                    cutIndex = output.index(after: i)
                    break
                }
            }
        }

        if newlineCount < maxLines {
            return output
        }

        return "[...truncated...]\n" + String(output[cutIndex...])
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
                Button("Reconfigure") {
                    onDismiss()
                    reconfigure()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Actions

    private func startServer() {
        Task {
            do {
                guard let worktreePath = card.worktreePath else { return }

                // Always check if this specific worktree needs setup
                // (each worktree is separate, may not have node_modules)
                let needsSetup = PackageJsonParser.isSetupNeeded(in: worktreePath)

                if needsSetup, let setup = setupCommand {
                    try await devServerManager.runSetup(
                        for: card.id,
                        command: setup,
                        directory: worktreePath
                    )
                }

                // Start dev server
                let url = try await devServerManager.startDevServer(
                    for: card.id,
                    command: devCommand,
                    directory: worktreePath
                )
                serverURL = url
            } catch {
                // Error is handled by DevServerManager state
            }
        }
    }

    private func handleWebViewError(_ error: String) {
        // If server just started, connection might fail initially
        // Retry a few times before showing error
        if retryCount < maxRetries {
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                reloadTrigger += 1
            }
        } else {
            webViewError = error
        }
    }
}
