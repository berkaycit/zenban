import SwiftUI

/// Fullscreen overlay view for dev server preview
struct DevServerView: View {
    let card: Card
    let setupCommand: String?
    let devCommand: String
    let onDismiss: () -> Void

    @Environment(DevServerManager.self) private var devServerManager
    @State private var serverURL: URL?
    @State private var isWebViewLoading = true
    @State private var reloadTrigger = 0
    @State private var webViewError: String?
    @State private var retryCount = 0

    private let maxRetries = 5

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
                        Button("Retry") {
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
        .onAppear {
            serverURL = url
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

            Button("Retry") {
                startServer()
            }

            Button("Close") {
                onDismiss()
            }
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
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
