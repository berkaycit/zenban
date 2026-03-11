import Foundation

enum ExecutableLocator {
    nonisolated static func resolve(
        _ executable: String,
        candidatePaths: [String],
        environment: [String: String]? = nil
    ) -> String? {
        if let candidate = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return candidate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]
        process.environment = environment
        process.standardError = FileHandle.nullDevice

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        return path
    }
}
