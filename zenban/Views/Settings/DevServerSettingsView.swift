import SwiftUI

struct DevServerSettingsView: View {
    let boardID: UUID?

    @Environment(BoardStore.self) private var store
    @State private var setupCommand = ""
    @State private var devCommand = ""
    @State private var skipSetup = false
    @State private var autoOpenConsole = false

    private var board: Board? {
        guard let boardID else { return nil }
        return store.board(for: boardID)
    }

    var body: some View {
        Form {
            if let board, let boardID {
                Section {
                    HStack {
                        Text("Board")
                        Spacer()
                        Text(board.name)
                            .foregroundStyle(.secondary)
                    }

                    if let path = board.repositoryPath {
                        HStack {
                            Text("Repository")
                            Spacer()
                            Text((path as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if board.repositoryPath != nil {
                    Section("Setup") {
                        TextField("Setup Command", text: $setupCommand, prompt: Text("npm install"))
                            .disabled(skipSetup)

                        Toggle("Skip setup step", isOn: $skipSetup)
                    }

                    Section("Dev Server") {
                        TextField("Dev Command", text: $devCommand, prompt: Text("npm run dev"))
                    }

                    Section("Preview") {
                        Toggle("Open console automatically", isOn: $autoOpenConsole)
                    }

                    Section {
                        HStack {
                            Spacer()
                            Button("Clear Configuration") {
                                store.clearDevServerConfig(boardID)
                                loadConfig()
                            }
                            .foregroundStyle(.red)
                            .disabled(board.devServerConfig == nil)
                        }
                    }
                } else {
                    Section {
                        Text("No repository linked to this board.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label("No Board Selected", systemImage: "square.dashed")
                    } description: {
                        Text("Select a board from the sidebar to configure its dev server settings.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadConfig()
        }
        .onChange(of: boardID) {
            loadConfig()
        }
        .onChange(of: setupCommand) { _, _ in saveConfigDebounced() }
        .onChange(of: devCommand) { _, _ in saveConfigDebounced() }
        .onChange(of: skipSetup) { _, _ in saveConfigDebounced() }
        .onChange(of: autoOpenConsole) { _, _ in saveConfigDebounced() }
    }

    private func loadConfig() {
        guard let boardID, let config = store.board(for: boardID)?.devServerConfig else {
            setupCommand = ""
            devCommand = ""
            skipSetup = false
            autoOpenConsole = false
            return
        }
        setupCommand = config.setupCommand ?? ""
        devCommand = config.devCommand
        skipSetup = config.skipSetup
        autoOpenConsole = config.autoOpenConsole
    }

    private func saveConfigDebounced() {
        guard let boardID, board?.repositoryPath != nil else { return }

        // Only save if we have meaningful content
        guard !devCommand.isEmpty || !setupCommand.isEmpty || skipSetup || autoOpenConsole else { return }

        let config = DevServerConfig(
            setupCommand: setupCommand.isEmpty ? nil : setupCommand,
            devCommand: devCommand.isEmpty ? "npm run dev" : devCommand,
            skipSetup: skipSetup,
            autoOpenConsole: autoOpenConsole
        )
        store.updateDevServerConfig(boardID, config: config)
    }
}
