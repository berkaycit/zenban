import SwiftUI

struct TerminalSettingsView: View {
    var body: some View {
        Form {
            Section("Configuration") {
                Text("Terminal appearance is configured via your Ghostty config file.")
                    .foregroundStyle(.secondary)

                Button("Open Ghostty Config") {
                    let configPath = NSString(string: "~/.config/ghostty/config").expandingTildeInPath
                    let configURL = URL(fileURLWithPath: configPath)

                    // Create config directory and file if they don't exist
                    let configDir = configURL.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: configPath) {
                        FileManager.default.createFile(atPath: configPath, contents: nil)
                    }

                    NSWorkspace.shared.open(configURL)
                }
            }
        }
        .formStyle(.grouped)
    }
}
