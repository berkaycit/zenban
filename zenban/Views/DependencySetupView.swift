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

                Text("Dependency Setup")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(headerDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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

                    Button(action: dismiss) {
                        Text(secondaryActionTitle)
                            .frame(width: 100)
                    }
                    .buttonStyle(DependencyButtonStyle(isPrimary: false))
                } else if !store.isInstallingDependency {
                    Button(action: store.dismissDependencySetup) {
                        Text("Continue")
                            .frame(width: 100)
                    }
                    .buttonStyle(DependencyButtonStyle(isPrimary: true))
                }
            }

            // Warning for skip
            if hasMissingDependencies && !store.isInstallingDependency {
                Text(footerDescription)
                    .font(.caption)
                    .foregroundStyle(hasMissingRequiredDependencies ? .orange : .secondary)
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
                dismiss()
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

    private var hasMissingRequiredDependencies: Bool {
        !(status?.allRequired ?? false)
    }

    private var hasMissingOptionalDependencies: Bool {
        status?.hasMissingOptionalDependencies ?? false
    }

    private var headerDescription: String {
        if hasMissingRequiredDependencies {
            return "Zenban needs Homebrew and tmux for terminal cards. GitHub CLI and Claude Code CLI stay optional."
        }
        if hasMissingOptionalDependencies {
            return "Required dependencies are installed. Optional tools can still be added for PR creation and AI commit messages."
        }
        return "All runtime dependencies are installed."
    }

    private var footerDescription: String {
        if hasMissingRequiredDependencies {
            return "Zenban's terminal cards will not work correctly until Homebrew and tmux are installed."
        }
        return "GitHub CLI and Claude Code CLI can be installed later from Settings."
    }

    private var secondaryActionTitle: String {
        if store.dependencySetupIsBlocking && hasMissingRequiredDependencies {
            return "Skip for Now"
        }
        if hasMissingOptionalDependencies && !hasMissingRequiredDependencies {
            return "Continue"
        }
        return "Close"
    }

    private var status: DependencyCheckService.Status? {
        store.dependencyStatus
    }

    private func isInstalled(_ dependency: DependencyCheckService.Dependency) -> Bool {
        store.dependencyStatus?[dependency] ?? false
    }

    private func dismiss() {
        if store.dependencySetupIsBlocking && hasMissingRequiredDependencies {
            store.skipDependencySetup()
        } else {
            store.dismissDependencySetup()
        }
    }

    private func installMissing() {
        let wasBlocking = store.dependencySetupIsBlocking
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

            if updatedStatus.allSatisfied ||
               (wasBlocking && updatedStatus.allRequired) {
                try? await Task.sleep(for: .seconds(1.5))
                await MainActor.run {
                    store.dismissDependencySetup()
                }
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
                    Text(isRequired ? "Required" : "Optional")
                        .font(.caption)
                        .foregroundStyle(isRequired ? .blue : .secondary)
                }
                Text(dependency.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(isInstalled ? "Installed" : "Missing")
                .font(.caption)
                .foregroundStyle(isInstalled ? .green : (isRequired ? .red : .orange))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    (isInstalled ? Color.green : (isRequired ? Color.red : Color.orange)).opacity(0.15),
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
