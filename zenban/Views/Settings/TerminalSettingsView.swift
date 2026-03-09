import SwiftUI

struct TerminalSettingsView: View {
    @Environment(BoardStore.self) private var store

    var body: some View {
        Form {
            Section("Configuration") {
                Text("Zenban uses the standard Ghostty configuration files, matching cmux.")
                    .foregroundStyle(.secondary)
                Text("Primary paths: ~/.config/ghostty/config(.ghostty) and ~/Library/Application Support/com.mitchellh.ghostty/config(.ghostty).")
                    .foregroundStyle(.secondary)
                Text("tmux runs underneath the visible Ghostty surface so card terminals can stay alive while they are not rendered.")
                    .foregroundStyle(.secondary)
            }

            Section("Session Runtime") {
                dependencyStatusRow(
                    name: "Homebrew",
                    installed: store.dependencyStatus?.homebrew ?? false,
                    isRequired: true
                )
                dependencyStatusRow(
                    name: "tmux",
                    installed: store.dependencyStatus?.tmux ?? false,
                    isRequired: true
                )

                if !(store.dependencyStatus?.allRequired ?? false) {
                    Text("Install missing required dependencies from General > Dependencies before relying on background terminal persistence.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Required terminal dependencies are installed. GitHub CLI and Claude Code CLI are optional and managed from General > Dependencies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if store.dependencyStatus == nil {
                store.checkDependencies()
            }
        }
    }

    @ViewBuilder
    private func dependencyStatusRow(name: String, installed: Bool, isRequired: Bool) -> some View {
        HStack {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(installed ? .green : (isRequired ? .red : .orange))

            Text(name)

            Text(isRequired ? "Required" : "Optional")
                .font(.caption)
                .foregroundStyle(isRequired ? .blue : .secondary)

            Spacer()

            Text(installed ? "Installed" : "Missing")
                .font(.caption)
                .foregroundStyle(installed ? .green : (isRequired ? .red : .orange))
        }
    }
}
