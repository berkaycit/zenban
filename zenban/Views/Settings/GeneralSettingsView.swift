import SwiftUI

struct GeneralSettingsView: View {
    @Environment(BoardStore.self) private var store

    var body: some View {
        @Bindable var store = store

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
                Text("Homebrew and tmux are required for Zenban terminals. GitHub CLI and Claude Code CLI remain optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(DependencyCheckService.Dependency.allCases, id: \.self) { dep in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: isInstalled(dep) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(isInstalled(dep) ? .green : (dep.isRequired ? .red : .orange))

                            Text(dep.rawValue)
                                .fontWeight(.medium)

                            Text(dep.isRequired ? "Required" : "Optional")
                                .font(.caption)
                                .foregroundStyle(dep.isRequired ? .blue : .secondary)

                            Spacer()

                            Text(isInstalled(dep) ? "Installed" : "Missing")
                                .font(.caption)
                                .foregroundStyle(isInstalled(dep) ? .green : (dep.isRequired ? .red : .orange))
                        }

                        Text(dep.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Check Again") {
                        store.checkDependencies()
                    }

                    if hasMissingDependencies {
                        Button(hasMissingRequiredDependencies ? "Install Missing" : "Install Optional Tools") {
                            store.presentDependencySetup()
                        }
                    }
                }
            } header: {
                Text("Dependencies")
            } footer: {
                if hasMissingRequiredDependencies {
                    Text("Zenban will keep prompting for missing required dependencies unless you explicitly skip the startup check.")
                } else if hasMissingDependencies {
                    Text("Optional tools can be installed later without affecting terminal behavior.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if store.dependencyStatus == nil {
                store.checkDependencies()
            }
        }
        .sheet(isPresented: $store.showDependencySetup) {
            DependencySetupView()
                .frame(minWidth: 420, minHeight: 400)
        }
    }

    private func isInstalled(_ dependency: DependencyCheckService.Dependency) -> Bool {
        store.dependencyStatus?[dependency] ?? false
    }

    private var hasMissingRequiredDependencies: Bool {
        !(store.dependencyStatus?.allRequired ?? false)
    }

    private var hasMissingDependencies: Bool {
        store.dependencyStatus?.hasMissingDependencies ?? true
    }
}
