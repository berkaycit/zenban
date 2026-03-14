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
                Text("Optional tools can still be installed here for pull request creation and AI-assisted commit messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(DependencyCheckService.Dependency.allCases, id: \.self) { dependency in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: isInstalled(dependency) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(isInstalled(dependency) ? .green : .orange)

                            Text(dependency.rawValue)
                                .fontWeight(.medium)

                            Text("Optional")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text(isInstalled(dependency) ? "Installed" : "Missing")
                                .font(.caption)
                                .foregroundStyle(isInstalled(dependency) ? .green : .orange)
                        }

                        Text(dependency.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Check Again") {
                        store.checkDependencies()
                    }

                    if hasMissingDependencies {
                        Button("Install Missing Tools") {
                            store.presentDependencySetup()
                        }
                    }
                }
            } header: {
                Text("Dependencies")
            } footer: {
                if hasMissingDependencies {
                    Text("Optional tools can be installed later without affecting the rest of the app.")
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

    private var hasMissingDependencies: Bool {
        store.dependencyStatus?.hasMissingDependencies ?? true
    }
}
