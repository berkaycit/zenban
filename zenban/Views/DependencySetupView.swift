//
//  DependencySetupView.swift
//  zenban
//
//  Modal view for checking and installing optional tools
//

import SwiftUI

struct DependencySetupView: View {
    @Environment(BoardStore.self) private var store
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text("Dependency Setup")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(headerDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                ForEach(DependencyCheckService.Dependency.allCases, id: \.self) { dependency in
                    DependencyRow(
                        dependency: dependency,
                        isInstalled: isInstalled(dependency)
                    )
                }
            }
            .padding(.vertical, 8)

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

            if store.isInstallingDependency {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Installing...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                if hasMissingDependencies && !store.isInstallingDependency {
                    Button(action: installMissing) {
                        Text("Install Missing")
                            .frame(width: 120)
                    }
                    .buttonStyle(DependencyButtonStyle(isPrimary: true))

                    Button(action: store.dismissDependencySetup) {
                        Text("Close")
                            .frame(width: 100)
                    }
                    .buttonStyle(DependencyButtonStyle(isPrimary: false))
                } else if !store.isInstallingDependency {
                    Button(action: store.dismissDependencySetup) {
                        Text("Close")
                            .frame(width: 100)
                    }
                    .buttonStyle(DependencyButtonStyle(isPrimary: true))
                }
            }

            if hasMissingDependencies && !store.isInstallingDependency {
                Text("You can return here later without affecting the rest of the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
                store.dismissDependencySetup()
            }
            return .handled
        }
        .onKeyPress(.return) {
            if !store.isInstallingDependency {
                if hasMissingDependencies {
                    installMissing()
                } else {
                    store.dismissDependencySetup()
                }
            }
            return .handled
        }
    }

    private var hasMissingDependencies: Bool {
        status?.hasMissingDependencies ?? true
    }

    private var headerDescription: String {
        if hasMissingDependencies {
            return "Install optional tools used for pull requests and AI-assisted commit messages."
        }
        return "All optional tools are installed."
    }

    private var status: DependencyCheckService.Status? {
        store.dependencyStatus
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
                    Task { @MainActor in
                        store.installationOutput += output
                    }
                }
            } catch {
                await MainActor.run {
                    store.installationOutput += "\nError: \(error.localizedDescription)\n"
                }
            }

            let updatedStatus = DependencyCheckService.shared.checkAll()
            await MainActor.run {
                store.dependencyStatus = updatedStatus
                store.isInstallingDependency = false
            }

            if updatedStatus.allSatisfied {
                try? await Task.sleep(for: .seconds(1.5))
                await MainActor.run {
                    store.dismissDependencySetup()
                }
            }
        }
    }
}

private struct DependencyRow: View {
    let dependency: DependencyCheckService.Dependency
    let isInstalled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isInstalled ? .green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dependency.rawValue)
                        .fontWeight(.medium)
                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
