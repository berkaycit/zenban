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

            Section("Dependencies") {
                ForEach(DependencyCheckService.Dependency.allCases, id: \.self) { dep in
                    HStack {
                        Image(systemName: isInstalled(dep) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isInstalled(dep) ? .green : (dep.isRequired ? .red : .orange))

                        Text(dep.rawValue)

                        if !dep.isRequired {
                            Text("(Optional)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(isInstalled(dep) ? "Installed" : "Missing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Check Again") {
                        store.checkDependencies()
                    }

                    if store.dependencyStatus?.allSatisfied == false {
                        Button("Install Missing") {
                            store.showDependencySetup = true
                        }
                    }
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
}
