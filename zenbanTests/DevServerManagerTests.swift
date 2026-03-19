import Testing
import Darwin
import Foundation
@testable import zenban

struct DevServerManagerTests {
    private static let ownedProcessGroupsDefaultsKey = "zenban.devServer.ownedProcessGroups.v2"

    @Test
    func parsePortConflictPortReadsEaddrinuseOutput() {
        let output = """
        Error: listen EADDRINUSE: address already in use :::3000
            at Server.setupListenHandle [as _listen2] (node:net:2008:16)
        """

        #expect(DevServerManager.parsePortConflictPort(output) == 3000)
    }

    @Test
    func commandBelongsToDirectoryOnlyMatchesSameWorktree() {
        let directory = "/Users/test/repo-worktrees/card/ABC123"
        let matching = "node \(directory)/node_modules/playable-scripts/dev.js"
        let other = "node /Users/test/another-repo/node_modules/playable-scripts/dev.js"

        #expect(DevServerManager.commandBelongsToDirectory(matching, directory: directory))
        #expect(!DevServerManager.commandBelongsToDirectory(other, directory: directory))
    }

    @Test
    func commandWithPortOverrideForwardsPortToNpmScripts() {
        let freePort = Self.findAvailableTCPPort()

        let defaults = UserDefaults.standard
        let originalBase = defaults.object(forKey: "cmuxPortBase")
        let originalRange = defaults.object(forKey: "cmuxPortRange")
        defaults.set(freePort, forKey: "cmuxPortBase")
        defaults.set(1, forKey: "cmuxPortRange")
        defer {
            Self.restoreDefault(originalBase, forKey: "cmuxPortBase")
            Self.restoreDefault(originalRange, forKey: "cmuxPortRange")
        }

        let output = """
        @smoud/playable-scripts v1.2.3
        Error: listen EADDRINUSE: address already in use :::3000
        """

        let override = DevServerManager.commandWithPortOverrideIfSupported(
            command: "npm run dev",
            output: output,
            conflictingPort: 3000
        )

        #expect(override?.port == freePort)
        #expect(override?.command == "npm run dev -- --port \(freePort)")
    }

    @Test
    func commandWithPortOverrideRespectsExplicitPortFlags() {
        let output = """
        @smoud/playable-scripts v1.2.3
        Error: listen EADDRINUSE: address already in use :::3000
        """

        let override = DevServerManager.commandWithPortOverrideIfSupported(
            command: "npm run dev -- --port 3000",
            output: output,
            conflictingPort: 3000
        )

        #expect(override == nil)
    }

    @Test
    func terminateProcessGroupsStopsRunningProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let processGroupID = getpgid(process.processIdentifier)
        #expect(processGroupID > 1)
        #expect(DevServerManager.terminateProcessGroups([processGroupID]))

        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal || process.terminationStatus == 0)
    }

    @Test
    func initReapsStalePersistedOwnedProcessGroups() throws {
        let defaults = UserDefaults.standard
        let originalValue = defaults.data(forKey: Self.ownedProcessGroupsDefaultsKey)
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cd '\(tempDirectory.path)' && sleep 30"]

        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: tempDirectory)
            if let originalValue {
                defaults.set(originalValue, forKey: Self.ownedProcessGroupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.ownedProcessGroupsDefaultsKey)
            }
        }

        try process.run()
        let processGroupID = getpgid(process.processIdentifier)
        let payload = [
            [
                "processGroupID": Int(processGroupID),
                "directory": tempDirectory.path,
            ]
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: payload),
            forKey: Self.ownedProcessGroupsDefaultsKey
        )

        _ = DevServerManager()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(!process.isRunning)
        if !process.isRunning {
            process.waitUntilExit()
        }
        #expect(defaults.data(forKey: Self.ownedProcessGroupsDefaultsKey) == nil)
    }

    private static func restoreDefault(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func findAvailableTCPPort() -> Int {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        precondition(descriptor >= 0)
        defer { close(descriptor) }

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.stride)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(0)
        address.sin6_addr = in6addr_any

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                bind(descriptor, sockPointer, socklen_t(MemoryLayout<sockaddr_in6>.stride))
            }
        }
        precondition(bound == 0)

        var resolvedAddress = sockaddr_in6()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.stride)
        let resolved = withUnsafeMutablePointer(to: &resolvedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                getsockname(descriptor, sockPointer, &addressLength)
            }
        }
        precondition(resolved == 0)

        return Int(UInt16(bigEndian: resolvedAddress.sin6_port))
    }
}
