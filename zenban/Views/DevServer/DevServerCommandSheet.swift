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
    @State private var autoOpenConsole = false
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
        .onAppear {
            loadExistingConfigOrDetect()
        }
    }

    private func loadExistingConfigOrDetect() {
        // If config exists, use it
        if let existingConfig = store.board(for: boardID)?.devServerConfig {
            setupCommand = existingConfig.setupCommand ?? ""
            devCommand = existingConfig.devCommand
            skipSetup = existingConfig.skipSetup
            autoOpenConsole = existingConfig.autoOpenConsole

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
                Divider()
                previewSection
            }
        }
        .padding(16)
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup Command")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("npm install", text: $setupCommand)
                    .textFieldStyle(.roundedBorder)
                    .disabled(skipSetup)

                if detectedCommands?.setupCommand != nil {
                    Button(action: { setupCommand = detectedCommands?.setupCommand ?? "" }) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to detected command")
                    .disabled(skipSetup)
                }
            }

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
        VStack(alignment: .leading, spacing: 8) {
            Text("Dev Command")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("npm run dev", text: $devCommand)
                    .textFieldStyle(.roundedBorder)

                if detectedCommands?.devCommand != nil {
                    Button(action: { devCommand = detectedCommands?.devCommand ?? "" }) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to detected command")
                }
            }

            if detectedCommands?.devCommand == nil {
                Label("No dev script found in package.json", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Open console automatically", isOn: $autoOpenConsole)
                .toggleStyle(.checkbox)

            Text("Opens the cmux browser console after the page finishes loading.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    skipSetup: skipSetup,
                    autoOpenConsole: autoOpenConsole
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
