import SwiftUI

struct TerminalSettingsView: View {
    var body: some View {
        Form {
            Section("Configuration") {
                Text("Zenban uses the standard Ghostty configuration files, matching cmux.")
                    .foregroundStyle(.secondary)
                Text("Primary paths: ~/.config/ghostty/config(.ghostty) and ~/Library/Application Support/com.mitchellh.ghostty/config(.ghostty).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
