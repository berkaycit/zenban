import Foundation

/// Shared utility for building process environment with proper PATH setup
enum ProcessEnvironment {
    /// Build environment dictionary with PATH that includes common tool locations
    /// Includes: homebrew, nvm node, npm global, macports, and standard paths
    nonisolated static func buildWithNodeSupport() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/local/bin",
        ]

        let currentPath = env["PATH"] ?? ""

        // Find node version manager paths (nvm, volta, fnm)
        var nodeManagerPaths: [String] = []

        // nvm: ~/.nvm/versions/node/vX.X.X/bin
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            if let latestVersion = versions.sorted().last {
                let binPath = "\(nvmDir)/\(latestVersion)/bin"
                if FileManager.default.fileExists(atPath: binPath) {
                    nodeManagerPaths.append(binPath)
                }
            }
        }

        // volta: ~/.volta/bin
        let voltaBin = "\(home)/.volta/bin"
        if FileManager.default.fileExists(atPath: voltaBin) {
            nodeManagerPaths.append(voltaBin)
        }

        // fnm: ~/.fnm/aliases/default/bin or ~/.local/share/fnm/aliases/default/bin
        for fnmBase in ["\(home)/.fnm", "\(home)/.local/share/fnm"] {
            let fnmBin = "\(fnmBase)/aliases/default/bin"
            if FileManager.default.fileExists(atPath: fnmBin) {
                nodeManagerPaths.append(fnmBin)
                break
            }
        }

        let allPaths = nodeManagerPaths + commonPaths

        let pathSet = Set(currentPath.split(separator: ":").map(String.init))
        let newPaths = allPaths.filter { !pathSet.contains($0) }

        env["PATH"] = (newPaths + [currentPath]).joined(separator: ":")

        // Prevent dev servers from opening browser (we have in-app preview)
        env["BROWSER"] = "none"

        return env
    }
}
