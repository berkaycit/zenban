//
//  DependencySetupView.swift
//  zenban
//
//  Modal view for checking and installing dependencies
//

import SwiftUI

struct DependencySetupView: View {
    @Environment(BoardStore.self) private var store
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text("Required Dependencies")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Zenban requires the following to function properly")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Status list
            VStack(spacing: 12) {
                ForEach(DependencyCheckService.Dependency.allCases, id: \.self) { dep in
                    DependencyRow(
                        dependency: dep,
                        isInstalled: isInstalled(dep),
                        isRequired: dep.isRequired
                    )
                }
            }
            .padding(.vertical, 8)

            // Installation output
            if store.isInstallingDependency || !store.installationOutput.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(store.installationOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("outputBottom")
                    }
                    .frame(height: 150)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: store.installationOutput) {
                        withAnimation {
                            proxy.scrollTo("outputBottom", anchor: .bottom)
                        }
                    }
                }
            }

            // Progress indicator
            if store.isInstallingDependency {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Installing...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Action buttons
            HStack(spacing: 12) {
                if hasMissingDependencies && !store.isInstallingDependency {
                    Button(action: installMissing) {
                        Text("Install Missing")
                            .frame(width: 120)
                    }
                    .buttonStyle(DependencyButtonStyle(isPrimary: true))

                    Button(action: store.skipDependencySetup) {
                        Text("Skip for Now")
                            .frame(width: 100)
                    }
                    .buttonStyle(DependencyButtonStyle(isPrimary: false))
                } else if !store.isInstallingDependency {
                    Button(action: { store.showDependencySetup = false }) {
                        Text("Continue")
                            .frame(width: 100)
                    }
                    .buttonStyle(DependencyButtonStyle(isPrimary: true))
                }
            }

            // Warning for skip
            if hasMissingDependencies && !store.isInstallingDependency {
                Text("Some features may not work without these dependencies")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(32)
        .frame(width: 420)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.escape) {
            if !store.isInstallingDependency {
                store.skipDependencySetup()
            }
            return .handled
        }
        .onKeyPress(.return) {
            if !store.isInstallingDependency {
                if hasMissingDependencies {
                    installMissing()
                } else {
                    store.showDependencySetup = false
                }
            }
            return .handled
        }
    }

    private var hasMissingDependencies: Bool {
        guard let status = store.dependencyStatus else { return true }
        return !status.allSatisfied
    }

    private func isInstalled(_ dependency: DependencyCheckService.Dependency) -> Bool {
        store.dependencyStatus?[dependency] ?? false
    }

    private func installMissing() {
        store.isInstallingDependency = true
        store.installationOutput = ""

        Task {
            do {
                try await DependencyCheckService.shared.installMissing { [store] output in
                    store.installationOutput += output
                }
            } catch {
                store.installationOutput += "\nError: \(error.localizedDescription)\n"
            }

            store.dependencyStatus = DependencyCheckService.shared.checkAll()
            store.isInstallingDependency = false

            if store.dependencyStatus?.allSatisfied == true {
                try? await Task.sleep(for: .seconds(1.5))
                store.showDependencySetup = false
            }
        }
    }
}

// MARK: - Subviews

private struct DependencyRow: View {
    let dependency: DependencyCheckService.Dependency
    let isInstalled: Bool
    let isRequired: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isInstalled ? .green : (isRequired ? .red : .orange))
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dependency.rawValue)
                        .fontWeight(.medium)
                    if !isRequired {
                        Text("(Optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(dependency.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(isInstalled ? "Installed" : "Missing")
                .font(.caption)
                .foregroundStyle(isInstalled ? .green : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    (isInstalled ? Color.green : Color.orange).opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Button Style

private struct DependencyButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(
                configuration.isPressed
                    ? (isPrimary ? Color.blue.opacity(0.8) : Color.secondary.opacity(0.3))
                    : (isPrimary ? Color.blue : Color.secondary.opacity(0.2))
            )
            .foregroundStyle(isPrimary ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
