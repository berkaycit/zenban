import Foundation

enum ClaudeHooksInstaller {
    private static let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    private static let requiredHooks: [String: Any] = [
        "UserPromptSubmit": [[
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": "[ -n \"$ZENBAN_TERMINAL\" ] && open 'zenban://prompt-submitted'"
            ]]
        ]],
        "Notification": [[
            "matcher": "idle_prompt",
            "hooks": [[
                "type": "command",
                "command": "[ -n \"$ZENBAN_TERMINAL\" ] && open 'zenban://notify?body=Task%20Completed'"
            ]]
        ]]
    ]

    enum InstallResult {
        case installed
        case alreadyInstalled
        case failed(String)
    }

    static func checkInstallationStatus() -> Bool {
        guard let settings = readSettings() else { return false }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }

        return hasRequiredHook(hooks, type: "UserPromptSubmit") &&
               hasRequiredHook(hooks, type: "Notification")
    }

    static func install() -> InstallResult {
        var settings = readSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var modified = false
        for hookType in requiredHooks.keys {
            if !hasRequiredHook(hooks, type: hookType) {
                var existing = hooks[hookType] as? [[String: Any]] ?? []
                if let newHook = requiredHooks[hookType] as? [[String: Any]] {
                    existing.append(contentsOf: newHook)
                }
                hooks[hookType] = existing
                modified = true
            }
        }

        guard modified else { return .alreadyInstalled }

        settings["hooks"] = hooks

        do {
            try FileManager.default.createDirectory(at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsPath)
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func hasRequiredHook(_ hooks: [String: Any], type: String) -> Bool {
        guard let hookArray = hooks[type] as? [[String: Any]] else { return false }

        let zenbanCommand = type == "UserPromptSubmit"
            ? "zenban://prompt-submitted"
            : "zenban://notify"

        return hookArray.contains { hookConfig in
            guard let innerHooks = hookConfig["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { hook in
                guard let command = hook["command"] as? String else { return false }
                return command.contains(zenbanCommand)
            }
        }
    }
}
