import Foundation
import Testing

struct ShellIntegrationLaunchRequestTests {
    @Test
    func bundledClaudeWrapperDisablesClaudeNativeNotificationChannel() throws {
        let wrapperURL = repositoryRoot()
            .appendingPathComponent("cmux-import/bin/claude", isDirectory: false)
        let contents = try String(contentsOf: wrapperURL, encoding: .utf8)

        #expect(FileManager.default.isExecutableFile(atPath: wrapperURL.path))
        #expect(contents.contains(#""preferredNotifChannel":"notifications_disabled""#))
        #expect(contents.contains(#""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude notification"#))
    }

    @Test
    func zshPromptConsumesQueuedZellijLaunchRequest() throws {
        try assertShellIntegrationConsumesLaunchRequest(
            shell: "/bin/zsh",
            arguments: ["-f", "-c"],
            integrationRelativePath: "cmux-import/shell-integration/cmux-zsh-integration.zsh",
            hookCommand: "_cmux_precmd",
            expectedOutput: "zsh-consumed"
        )
    }

    @Test
    func bashPromptConsumesQueuedZellijLaunchRequest() throws {
        try assertShellIntegrationConsumesLaunchRequest(
            shell: "/bin/bash",
            arguments: ["--noprofile", "--norc", "-c"],
            integrationRelativePath: "cmux-import/shell-integration/cmux-bash-integration.bash",
            hookCommand: "_cmux_prompt_command",
            expectedOutput: "bash-consumed"
        )
    }

    private func assertShellIntegrationConsumesLaunchRequest(
        shell: String,
        arguments: [String],
        integrationRelativePath: String,
        hookCommand: String,
        expectedOutput: String
    ) throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenban-shell-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let launchFile = tempDirectory.appendingPathComponent("launch-request")
        let outputFile = tempDirectory.appendingPathComponent("output")
        try "launch-token\nprintf \(shellQuoted(expectedOutput)) > \(shellQuoted(outputFile.path))\n"
            .write(to: launchFile, atomically: true, encoding: .utf8)

        let integrationPath = repositoryRoot()
            .appendingPathComponent(integrationRelativePath)
            .path
        let script = "source \(shellQuoted(integrationPath)); \(hookCommand)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments + [script]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_SOCKET_PATH": "/tmp/zenban-nonexistent-cmux.sock",
            "CMUX_TAB_ID": "tab-test",
            "CMUX_PANEL_ID": "panel-test",
            "CMUX_ZELLIJ_LAUNCH_FILE": launchFile.path,
        ]) { _, newValue in newValue }

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: launchFile.path))
        #expect((try? String(contentsOf: outputFile, encoding: .utf8)) == expectedOutput)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
