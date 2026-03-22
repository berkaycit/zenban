import Foundation
import Testing
@testable import zenban

@MainActor
struct ProcessEnvironmentTests {
    @Test
    func buildWithNodeSupportDisablesExternalBrowsers() {
        let environment = ProcessEnvironment.buildWithNodeSupport()
        #expect(environment["BROWSER"] == "none")
    }

    @Test
    func resolvedEnvironmentIncludesPanelIDsPortsAndZellijSocketDirectory() {
        let previousPortBase = UserDefaults.standard.object(forKey: "cmuxPortBase")
        let previousPortRange = UserDefaults.standard.object(forKey: "cmuxPortRange")
        let previousShellIntegration = UserDefaults.standard.object(forKey: "sidebarShellIntegration")
        defer {
            restoreDefaultsValue(previousPortBase, forKey: "cmuxPortBase")
            restoreDefaultsValue(previousPortRange, forKey: "cmuxPortRange")
            restoreDefaultsValue(previousShellIntegration, forKey: "sidebarShellIntegration")
        }

        UserDefaults.standard.set(9200, forKey: "cmuxPortBase")
        UserDefaults.standard.set(20, forKey: "cmuxPortRange")
        UserDefaults.standard.set(false, forKey: "sidebarShellIntegration")

        let panelID = UUID()
        let workspaceID = UUID()
        let environment = TerminalProcessEnvironment.resolvedEnvironment(
            panelId: panelID,
            workspaceId: workspaceID,
            portOrdinal: 2,
            inheritedEnvironment: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"],
            additionalEnvironment: ["CUSTOM_FLAG": "1"]
        )

        #expect(environment["CMUX_SURFACE_ID"] == panelID.uuidString)
        #expect(environment["CMUX_PANEL_ID"] == panelID.uuidString)
        #expect(environment["CMUX_WORKSPACE_ID"] == workspaceID.uuidString)
        #expect(environment["CMUX_TAB_ID"] == workspaceID.uuidString)
        #expect(environment["CMUX_PORT"] == "9240")
        #expect(environment["CMUX_PORT_END"] == "9259")
        #expect(environment["CMUX_PORT_RANGE"] == "20")
        #expect(environment["ZELLIJ_SOCKET_DIR"] == TerminalProcessEnvironment.zellijSocketDirectoryPath)
        #expect(environment["CUSTOM_FLAG"] == "1")
        #expect(environment["CMUX_SHELL_INTEGRATION"] == nil)
    }

    @Test
    func resolvedEnvironmentPrependsBundledPathsAndConfiguresShellIntegration() throws {
        let previousShellIntegration = UserDefaults.standard.object(forKey: "sidebarShellIntegration")
        defer {
            restoreDefaultsValue(previousShellIntegration, forKey: "sidebarShellIntegration")
        }

        UserDefaults.standard.set(true, forKey: "sidebarShellIntegration")
        let resourceURL = try #require(Bundle.main.resourceURL)
        let cliBinPath = resourceURL.appendingPathComponent("bin", isDirectory: true).path
        let integrationPath = resourceURL.appendingPathComponent("shell-integration", isDirectory: true).path

        let zshEnvironment = TerminalProcessEnvironment.resolvedEnvironment(
            panelId: UUID(),
            workspaceId: UUID(),
            portOrdinal: 0,
            inheritedEnvironment: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"]
        )
        #expect(zshEnvironment["PATH"]?.hasPrefix("\(cliBinPath):") == true)
        #expect(zshEnvironment["CMUX_SHELL_INTEGRATION"] == "1")
        #expect(zshEnvironment["CMUX_SHELL_INTEGRATION_DIR"] == integrationPath)
        #expect(zshEnvironment["ZDOTDIR"] == integrationPath)

        let bashEnvironment = TerminalProcessEnvironment.resolvedEnvironment(
            panelId: UUID(),
            workspaceId: UUID(),
            portOrdinal: 0,
            inheritedEnvironment: ["PATH": "/usr/bin", "SHELL": "/bin/bash"]
        )
        let promptCommand = try #require(bashEnvironment["PROMPT_COMMAND"])
        #expect(bashEnvironment["PATH"]?.hasPrefix("\(cliBinPath):") == true)
        #expect(bashEnvironment["CMUX_SHELL_INTEGRATION"] == "1")
        #expect(bashEnvironment["CMUX_SHELL_INTEGRATION_DIR"] == integrationPath)
        #expect(promptCommand.contains("cmux-bash-integration.bash"))
        #expect(promptCommand.contains("_cmux_prompt_command"))
    }

    private func restoreDefaultsValue(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
