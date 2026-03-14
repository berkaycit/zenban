import SwiftUI

/// Sheet for selecting/editing setup and dev commands before starting
struct DevServerCommandSheet: View {
    let worktreePath: String
    let boardID: UUID
    @Binding var isPresented: Bool
    let onStart: (String?, String) -> Void

    @Environment(BoardStore.self) private var store
    @State private var detectedCommands: PackageJsonParser.DetectedCommands?
    @State private var setupCommand = ""
    @State private var devCommand = ""
    @State private var skipSetup = false
    @State private var isDetecting = true

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            contentSection
            Divider()
            footerSection
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            loadExistingConfigOrDetect()
        }
    }

    private func loadExistingConfigOrDetect() {
        // If config exists, use it
        if let existingConfig = store.board(for: boardID)?.devServerConfig {
            setupCommand = existingConfig.setupCommand ?? ""
            devCommand = existingConfig.devCommand
            skipSetup = existingConfig.skipSetup

            // Still detect to show node_modules status
            Task {
                let commands = PackageJsonParser.detectCommands(in: worktreePath)
                await MainActor.run {
                    detectedCommands = commands
                    isDetecting = false
                }
            }
        } else {
            detectCommands()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("Dev Server Configuration")
                .font(.headline)
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isDetecting {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Detecting commands...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                setupSection
                Divider()
                devSection
            }
        }
        .padding(16)
    }

    private var setupSection: some View {
        CommandFieldSection(
            title: "Setup Command",
            placeholder: "npm install",
            text: $setupCommand,
            detectedCommand: detectedCommands?.setupCommand,
            isDisabled: skipSetup
        ) {
            Toggle(isOn: $skipSetup) {
                HStack(spacing: 4) {
                    Text("Skip setup")
                    if detectedCommands?.nodeModulesExists == true {
                        Text("(node_modules exists)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .toggleStyle(.checkbox)
        }
    }

    private var devSection: some View {
        CommandFieldSection(
            title: "Dev Command",
            placeholder: "npm run dev",
            text: $devCommand,
            detectedCommand: detectedCommands?.devCommand
        ) {
            if detectedCommands?.devCommand == nil {
                Label("No dev script found in package.json", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Button("Start") {
                let setup = skipSetup ? nil : (setupCommand.isEmpty ? nil : setupCommand)

                // Save config to board
                let config = DevServerConfig(
                    setupCommand: setupCommand.isEmpty ? nil : setupCommand,
                    devCommand: devCommand,
                    skipSetup: skipSetup
                )
                store.updateDevServerConfig(boardID, config: config)

                onStart(setup, devCommand)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(devCommand.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func detectCommands() {
        Task {
            let commands = PackageJsonParser.detectCommands(in: worktreePath)

            await MainActor.run {
                detectedCommands = commands
                setupCommand = commands.setupCommand ?? "npm install"
                devCommand = commands.devCommand ?? ""

                // Auto-skip setup if node_modules exists
                if commands.nodeModulesExists {
                    skipSetup = true
                }

                isDetecting = false
            }
        }
    }
}

private struct CommandFieldSection<AuxiliaryContent: View>: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let detectedCommand: String?
    let isDisabled: Bool
    private let auxiliaryContent: () -> AuxiliaryContent

    init(
        title: String,
        placeholder: String,
        text: Binding<String>,
        detectedCommand: String?,
        isDisabled: Bool = false,
        @ViewBuilder auxiliaryContent: @escaping () -> AuxiliaryContent
    ) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.detectedCommand = detectedCommand
        self.isDisabled = isDisabled
        self.auxiliaryContent = auxiliaryContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDisabled)

                if let detectedCommand {
                    Button(action: { text = detectedCommand }) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to detected command")
                    .disabled(isDisabled)
                }
            }

            auxiliaryContent()
        }
    }
}
