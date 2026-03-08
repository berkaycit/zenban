import SwiftUI

/// Sheet for editing board-level dev server configuration
struct DevServerSettingsSheet: View {
    let boardID: UUID
    @Binding var isPresented: Bool

    @Environment(BoardStore.self) private var store
    @State private var setupCommand = ""
    @State private var devCommand = ""
    @State private var skipSetup = false
    @State private var autoOpenConsole = false

    private var board: Board? { store.board(for: boardID) }

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
            loadConfig()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("Dev Server Settings")
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
            if board?.repositoryPath != nil {
                devServerSection
            } else {
                Text("No repository linked to this board.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            }
        }
        .padding(16)
    }

    private var devServerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dev Server Configuration")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Setup Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("npm install", text: $setupCommand)
                    .textFieldStyle(.roundedBorder)
                    .disabled(skipSetup)

                Toggle(isOn: $skipSetup) {
                    Text("Skip setup")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Dev Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("npm run dev", text: $devCommand)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

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

            if board?.devServerConfig == nil {
                Label("Not configured yet. Settings will be saved when you click Save.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            if board?.devServerConfig != nil {
                Button("Clear") {
                    store.clearDevServerConfig(boardID)
                    isPresented = false
                }
                .foregroundStyle(.red)
            }

            Spacer()

            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                saveConfig()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(board?.repositoryPath == nil)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func loadConfig() {
        if let config = store.board(for: boardID)?.devServerConfig {
            setupCommand = config.setupCommand ?? ""
            devCommand = config.devCommand
            skipSetup = config.skipSetup
            autoOpenConsole = config.autoOpenConsole
        }
    }

    private func saveConfig() {
        let config = DevServerConfig(
            setupCommand: setupCommand.isEmpty ? nil : setupCommand,
            devCommand: devCommand.isEmpty ? "npm run dev" : devCommand,
            skipSetup: skipSetup,
            autoOpenConsole: autoOpenConsole
        )
        store.updateDevServerConfig(boardID, config: config)
        isPresented = false
    }
}
