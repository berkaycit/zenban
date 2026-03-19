import Foundation

struct BoardStorage {
    private static let fileName = "boards.json"

    private static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["CMUX_UI_TEST_BOARD_STORAGE_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.berkaycit.zenban", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    static func load() -> [Board] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Board].self, from: data)
        } catch {
            print("Failed to load boards: \(error)")
            return []
        }
    }

    static func save(_ boards: [Board]) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(boards)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save boards: \(error)")
        }
    }
}
