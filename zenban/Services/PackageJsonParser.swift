import Foundation

/// Utility for detecting dev and setup commands from package.json and lock files
struct PackageJsonParser {

    struct DetectedCommands {
        let setupCommand: String?
        let devCommand: String?
        let nodeModulesExists: Bool
    }

    /// Detect setup and dev commands from a directory
    static func detectCommands(in directory: String) -> DetectedCommands {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: directory)

        // Check node_modules existence
        let nodeModulesPath = directoryURL.appendingPathComponent("node_modules").path
        let nodeModulesExists = fileManager.fileExists(atPath: nodeModulesPath)

        // Detect setup command based on lock file
        let setupCommand = detectSetupCommand(in: directory, fileManager: fileManager)

        // Detect dev command from package.json
        let devCommand = detectDevCommand(in: directory, fileManager: fileManager)

        return DetectedCommands(
            setupCommand: setupCommand,
            devCommand: devCommand,
            nodeModulesExists: nodeModulesExists
        )
    }

    /// Check if setup is needed (no node_modules or empty)
    static func isSetupNeeded(in directory: String) -> Bool {
        let fileManager = FileManager.default
        let nodeModulesPath = URL(fileURLWithPath: directory)
            .appendingPathComponent("node_modules").path

        // Check if node_modules exists
        guard fileManager.fileExists(atPath: nodeModulesPath) else {
            return true
        }

        // Check if node_modules has contents
        if let contents = try? fileManager.contentsOfDirectory(atPath: nodeModulesPath) {
            return contents.isEmpty
        }

        return true
    }

    // MARK: - Private

    private static func detectSetupCommand(in directory: String, fileManager: FileManager) -> String? {
        let directoryURL = URL(fileURLWithPath: directory)

        // Priority order for lock files
        let lockFileCommands: [(file: String, command: String)] = [
            ("package-lock.json", "npm install"),
            ("yarn.lock", "yarn install"),
            ("pnpm-lock.yaml", "pnpm install"),
            ("bun.lockb", "bun install")
        ]

        for (lockFile, command) in lockFileCommands {
            let lockPath = directoryURL.appendingPathComponent(lockFile).path
            if fileManager.fileExists(atPath: lockPath) {
                return command
            }
        }

        // Fallback: if package.json exists but no lock file, use npm
        let packageJsonPath = directoryURL.appendingPathComponent("package.json").path
        if fileManager.fileExists(atPath: packageJsonPath) {
            return "npm install"
        }

        return nil
    }

    private static func detectDevCommand(in directory: String, fileManager: FileManager) -> String? {
        let packageJsonPath = URL(fileURLWithPath: directory)
            .appendingPathComponent("package.json").path

        guard fileManager.fileExists(atPath: packageJsonPath),
              let data = fileManager.contents(atPath: packageJsonPath) else {
            return nil
        }

        guard let packageJson = try? JSONDecoder().decode(PackageJson.self, from: data) else {
            return nil
        }

        guard let scripts = packageJson.scripts else {
            return nil
        }

        // Priority order for dev scripts
        if scripts.dev != nil {
            return detectPackageManager(in: directory, fileManager: fileManager) + " run dev"
        }
        if scripts.start != nil {
            return detectPackageManager(in: directory, fileManager: fileManager) + " run start"
        }
        if scripts.serve != nil {
            return detectPackageManager(in: directory, fileManager: fileManager) + " run serve"
        }

        return nil
    }

    private static func detectPackageManager(in directory: String, fileManager: FileManager) -> String {
        let directoryURL = URL(fileURLWithPath: directory)

        if fileManager.fileExists(atPath: directoryURL.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }
        if fileManager.fileExists(atPath: directoryURL.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if fileManager.fileExists(atPath: directoryURL.appendingPathComponent("bun.lockb").path) {
            return "bun"
        }
        return "npm"
    }

    // MARK: - Models

    private struct PackageJson: Decodable {
        let scripts: Scripts?

        struct Scripts: Decodable {
            let dev: String?
            let start: String?
            let serve: String?
        }
    }
}
