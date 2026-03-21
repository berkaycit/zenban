import Darwin
import Foundation
#if DEBUG
import Bonsplit
#endif

@MainActor
enum TerminalProcessEnvironment {
    private static var sessionPortBase: Int {
        let value = UserDefaults.standard.integer(forKey: "cmuxPortBase")
        return value > 0 ? value : 9100
    }

    private static var sessionPortRangeSize: Int {
        let value = UserDefaults.standard.integer(forKey: "cmuxPortRange")
        return value > 0 ? value : 10
    }

    static var zellijSocketDirectoryPath: String {
        "/tmp/zenban-zellij-\(getuid())"
    }

    static func inheritedEnvironment(from config: ghostty_surface_config_s?) -> [String: String] {
        guard let config,
              config.env_var_count > 0,
              let existingEnv = config.env_vars else {
            return [:]
        }

        var inheritedEnvironment: [String: String] = [:]
        for index in 0..<Int(config.env_var_count) {
            let item = existingEnv[index]
            guard let key = String(cString: item.key, encoding: .utf8),
                  let value = String(cString: item.value, encoding: .utf8) else {
                continue
            }
            inheritedEnvironment[key] = value
        }
        return inheritedEnvironment
    }

    static func resolvedEnvironment(
        panelId: UUID,
        workspaceId: UUID,
        portOrdinal: Int,
        inheritedEnvironment: [String: String] = [:],
        additionalEnvironment: [String: String] = [:]
    ) -> [String: String] {
        var env = inheritedEnvironment

        env["CMUX_SURFACE_ID"] = panelId.uuidString
        env["CMUX_WORKSPACE_ID"] = workspaceId.uuidString
        env["CMUX_PANEL_ID"] = panelId.uuidString
        env["CMUX_TAB_ID"] = workspaceId.uuidString
        env["CMUX_SOCKET_PATH"] = SocketControlSettings.socketPath()
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            env["CMUX_BUNDLE_ID"] = bundleId
        }
        env["ZELLIJ_SOCKET_DIR"] = zellijSocketDirectoryPath

        let startPort = sessionPortBase + portOrdinal * sessionPortRangeSize
        env["CMUX_PORT"] = String(startPort)
        env["CMUX_PORT_END"] = String(startPort + sessionPortRangeSize - 1)
        env["CMUX_PORT_RANGE"] = String(sessionPortRangeSize)

        if !ClaudeCodeIntegrationSettings.hooksEnabled() {
            env["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
        }

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                let separator = currentPath.isEmpty ? "" : ":"
                env["PATH"] = "\(cliBinPath)\(separator)\(currentPath)"
            }
        }

        let shellIntegrationEnabled = UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true
        if shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path {
            env["CMUX_SHELL_INTEGRATION"] = "1"
            env["CMUX_SHELL_INTEGRATION_DIR"] = integrationDir

            let shell = (env["SHELL"]?.isEmpty == false ? env["SHELL"] : nil)
                ?? getenv("SHELL").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            if shellName == "zsh" {
                if GhosttyApp.shared.shellIntegrationMode() != "none" {
                    env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
                }
                let candidateZdotdir = (env["ZDOTDIR"]?.isEmpty == false ? env["ZDOTDIR"] : nil)
                    ?? getenv("ZDOTDIR").map { String(cString: $0) }
                    ?? (ProcessInfo.processInfo.environment["ZDOTDIR"]?.isEmpty == false
                        ? ProcessInfo.processInfo.environment["ZDOTDIR"]
                        : nil)

                if let candidateZdotdir, !candidateZdotdir.isEmpty {
                    var isGhosttyInjected = false
                    let ghosttyResources = (env["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? env["GHOSTTY_RESOURCES_DIR"] : nil)
                        ?? getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) }
                        ?? (ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false
                            ? ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
                            : nil)
                    if let ghosttyResources {
                        let ghosttyZdotdir = URL(fileURLWithPath: ghosttyResources)
                            .appendingPathComponent("shell-integration/zsh").path
                        isGhosttyInjected = candidateZdotdir == ghosttyZdotdir
                    }
                    if !isGhosttyInjected {
                        env["CMUX_ZSH_ZDOTDIR"] = candidateZdotdir
                    }
                }

                env["ZDOTDIR"] = integrationDir
            } else if shellName == "bash" {
                if GhosttyApp.shared.shellIntegrationMode() != "none" {
                    env["CMUX_LOAD_GHOSTTY_BASH_INTEGRATION"] = "1"
                }
                env["PROMPT_COMMAND"] = """
                unset PROMPT_COMMAND; \
                if [[ "${CMUX_LOAD_GHOSTTY_BASH_INTEGRATION:-0}" == "1" && -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then \
                _cmux_ghostty_bash="$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash"; \
                [[ -r "$_cmux_ghostty_bash" ]] && source "$_cmux_ghostty_bash"; \
                fi; \
                if [[ "${CMUX_SHELL_INTEGRATION:-1}" != "0" && -n "${CMUX_SHELL_INTEGRATION_DIR:-}" ]]; then \
                _cmux_bash_integration="$CMUX_SHELL_INTEGRATION_DIR/cmux-bash-integration.bash"; \
                [[ -r "$_cmux_bash_integration" ]] && source "$_cmux_bash_integration"; \
                fi; \
                unset _cmux_ghostty_bash _cmux_bash_integration; \
                if declare -F _cmux_prompt_command >/dev/null 2>&1; then _cmux_prompt_command; fi
                """
            }
        }

        for (key, value) in additionalEnvironment where !key.isEmpty && !value.isEmpty {
            env[key] = value
        }

        return env
    }
}

#if DEBUG
enum DebugProcessMemory {
    struct Snapshot {
        let residentSize: UInt64
        let physFootprint: UInt64
        let compressed: UInt64
    }

    static func snapshot() -> Snapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    integerPointer,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Snapshot(
            residentSize: info.resident_size,
            physFootprint: info.phys_footprint,
            compressed: info.compressed
        )
    }

    static func summary() -> String {
        guard let snapshot = snapshot() else {
            return "mem.residentMB=unavailable mem.footprintMB=unavailable mem.compressedMB=unavailable"
        }
        return [
            "mem.residentMB=\(mbString(snapshot.residentSize))",
            "mem.footprintMB=\(mbString(snapshot.physFootprint))",
            "mem.compressedMB=\(mbString(snapshot.compressed))",
        ].joined(separator: " ")
    }

    static func log(
        _ event: String,
        workspaceId: UUID? = nil,
        panelId: UUID? = nil,
        extra: String? = nil
    ) {
        var parts = [event, summary()]
        if let workspaceId {
            parts.append("workspace=\(workspaceId.uuidString.prefix(5))")
        }
        if let panelId {
            parts.append("panel=\(panelId.uuidString.prefix(5))")
        }
        if let extra {
            let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        dlog(parts.joined(separator: " "))
    }

    private static func mbString(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / (1024 * 1024))
    }
}
#endif
