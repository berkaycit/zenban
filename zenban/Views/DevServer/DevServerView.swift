import SwiftUI

enum ConsolePosition: String {
    case bottom
    case left

    var isHorizontal: Bool { self == .bottom }

    var resizeCursor: NSCursor {
        isHorizontal ? .resizeUpDown : .resizeLeftRight
    }

    var toggleIcon: String {
        isHorizontal ? "rectangle.lefthalf.inset.filled" : "rectangle.bottomhalf.inset.filled"
    }

    var toggleHelp: String {
        isHorizontal ? "Move to Left" : "Move to Bottom"
    }

    mutating func toggle() {
        self = isHorizontal ? .left : .bottom
    }
}

private let consoleAnimation = Animation.easeOut(duration: 0.15)

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
    @AppStorage("devServerConsolePosition") private var consolePosition: ConsolePosition = .left
    @State private var consoleHeight: CGFloat = 250
    @State private var consoleWidth: CGFloat = 320

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
        .onReceive(NotificationCenter.default.publisher(for: .reloadDevServer)) { _ in
            devServerManager.clearOutput(for: card.id)
            reloadTrigger += 1
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
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

                Button(action: { withAnimation(consoleAnimation) { showConsole.toggle() } }) {
                    Image(systemName: "terminal")
                        .foregroundStyle(showConsole ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle Console")
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
    private var contentSection: some View {
        let state = devServerManager.state(for: card.id)

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

    private func outputView(title: String, showSpinner: Bool) -> some View {
        // Observe version for throttled updates
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
        HStack(spacing: 0) {
            if !line.prefix.isEmpty {
                Text(line.prefix)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(lineColor(for: line).opacity(0.7))
            }
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(lineColor(for: line))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func webViewSection(url: URL) -> some View {
        Group {
            if consolePosition.isHorizontal {
                VStack(spacing: 0) {
                    webViewContent(url: url)
                    if showConsole {
                        Divider()
                        consoleSection
                    }
                }
            } else {
                HStack(spacing: 0) {
                    if showConsole {
                        consoleSection
                        Divider()
                    }
                    webViewContent(url: url)
                }
            }
        }
        .onAppear {
            serverURL = url
        }
    }

    @ViewBuilder
    private func webViewContent(url: URL) -> some View {
        ZStack {
            ReloadableWebView(
                url: url,
                isLoading: $isWebViewLoading,
                reloadTrigger: $reloadTrigger,
                onError: { error in
                    handleWebViewError(error)
                },
                onConsoleMessage: { message in
                    devServerManager.addBrowserConsoleMessage(
                        for: card.id,
                        level: message.level.rawValue,
                        message: message.message
                    )
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
    }

    private var consoleSection: some View {
        let mainContent = VStack(spacing: 0) {
            consoleHeader
            consoleContent
        }

        return Group {
            if consolePosition.isHorizontal {
                VStack(spacing: 0) {
                    resizeHandle
                    mainContent
                }
            } else {
                HStack(spacing: 0) {
                    mainContent
                    resizeHandle
                }
            }
        }
        .frame(
            width: consolePosition.isHorizontal ? nil : consoleWidth,
            height: consolePosition.isHorizontal ? consoleHeight : nil
        )
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private var resizeHandle: some View {
        let isHorizontal = consolePosition.isHorizontal

        return Rectangle()
            .fill(Color.clear)
            .frame(width: isHorizontal ? nil : 6, height: isHorizontal ? 6 : nil)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if isHorizontal {
                            consoleHeight = max(100, min(500, consoleHeight - value.translation.height))
                        } else {
                            consoleWidth = max(200, min(600, consoleWidth + value.translation.width))
                        }
                    }
            )
            .onHover { hovering in
                if hovering {
                    consolePosition.resizeCursor.push()
                } else {
                    NSCursor.pop()
                }
            }
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

            Button(action: { withAnimation(consoleAnimation) { consolePosition.toggle() } }) {
                Image(systemName: consolePosition.toggleIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(consolePosition.toggleHelp)

            Button(action: { withAnimation(consoleAnimation) { showConsole = false } }) {
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
        let lines = devServerManager.outputLinesArray(for: card.id)

        return ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty {
                        Text("Waiting for output...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(buildAttributedConsoleOutput(lines))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
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

    /// Build attributed string with colors for all console lines
    private func buildAttributedConsoleOutput(_ lines: [OutputLine]) -> AttributedString {
        var result = AttributedString()

        for (index, line) in lines.enumerated() {
            // Add prefix if present
            if !line.prefix.isEmpty {
                var prefix = AttributedString(line.prefix)
                prefix.foregroundColor = nsColor(for: line).withAlphaComponent(0.7)
                result.append(prefix)
            }

            // Add line text
            var text = AttributedString(line.text)
            text.foregroundColor = nsColor(for: line)
            result.append(text)

            // Add newline except for last line
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }

        return result
    }

    private func lineColor(for line: OutputLine) -> Color {
        if line.isError { return .red }
        if line.isWarning { return .orange }
        if line.isBrowser { return .cyan }
        return .primary
    }

    private func nsColor(for line: OutputLine) -> NSColor {
        NSColor(lineColor(for: line))
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
