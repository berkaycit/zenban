import SwiftUI

struct GeneralSettingsView: View {
    @Environment(BoardStore.self) private var store

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Zenban")
                            .font(.title2)
                            .fontWeight(.semibold)

                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("Version \(version)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Section {
                Text("Zenban bundles its terminal tooling internally. Git and Claude Code CLI stay external and are only used for the features below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(DependencyCheckService.Dependency.allCases, id: \.self) { dependency in
                    ToolAvailabilityRow(
                        dependency: dependency,
                        isAvailable: isAvailable(dependency)
                    )
                }

                Button("Refresh") {
                    store.checkDependencies()
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Zenban does not require separate Homebrew, tmux, zellij, or GitHub CLI installs.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if store.dependencyStatus == nil {
                store.checkDependencies()
            }
        }
    }

    private func isAvailable(_ dependency: DependencyCheckService.Dependency) -> Bool {
        store.dependencyStatus?[dependency] ?? false
    }
}

private struct ToolAvailabilityRow: View {
    let dependency: DependencyCheckService.Dependency
    let isAvailable: Bool

    private var tint: Color {
        isAvailable ? .green : .orange
    }

    private var statusText: String {
        isAvailable ? "Available" : "Unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)

                Text(dependency.rawValue)
                    .fontWeight(.medium)

                Spacer()

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(tint)
            }

            Text(dependency.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
