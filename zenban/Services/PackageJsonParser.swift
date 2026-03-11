import Foundation

/// Utility for detecting dev and setup commands from package.json and lock files
struct PackageJsonParser {
    private enum PackageManager: String {
        case npm
        case yarn
        case pnpm
        case bun

        var lockFileName: String {
            switch self {
            case .npm:
                "package-lock.json"
            case .yarn:
                "yarn.lock"
            case .pnpm:
                "pnpm-lock.yaml"
            case .bun:
                "bun.lockb"
            }
        }

        var installCommand: String {
            "\(rawValue) install"
        }
    }

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

        if let packageManager = packageManagerForExistingLockfile(
            in: directoryURL,
            fileManager: fileManager,
            priority: [.npm, .yarn, .pnpm, .bun]
        ) {
            return packageManager.installCommand
        }

        // Fallback: if package.json exists but no lock file, use npm
        let packageJsonPath = directoryURL.appendingPathComponent("package.json").path
        if fileManager.fileExists(atPath: packageJsonPath) {
            return PackageManager.npm.installCommand
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

        let packageManager = detectPackageManager(in: directory, fileManager: fileManager)

        // Priority order for dev scripts
        if scripts.dev != nil {
            return packageManager + " run dev"
        }
        if scripts.start != nil {
            return packageManager + " run start"
        }
        if scripts.serve != nil {
            return packageManager + " run serve"
        }

        return nil
    }

    private static func detectPackageManager(in directory: String, fileManager: FileManager) -> String {
        let directoryURL = URL(fileURLWithPath: directory)

        return packageManagerForExistingLockfile(
            in: directoryURL,
            fileManager: fileManager,
            priority: [.yarn, .pnpm, .bun, .npm]
        )?.rawValue ?? PackageManager.npm.rawValue
    }

    private static func packageManagerForExistingLockfile(
        in directoryURL: URL,
        fileManager: FileManager,
        priority: [PackageManager]
    ) -> PackageManager? {
        priority.first { packageManager in
            let lockFilePath = directoryURL.appendingPathComponent(packageManager.lockFileName).path
            return fileManager.fileExists(atPath: lockFilePath)
        }
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
