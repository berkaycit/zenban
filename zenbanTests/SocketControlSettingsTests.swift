import Testing
@testable import zenban

struct SocketControlSettingsTests {
    @Test
    func zenbanDebugBuildUsesDedicatedSocketPath() {
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: SocketControlSettings.zenbanBundleIdentifier,
                isDebugBuild: true
            ) == SocketControlSettings.zenbanDebugSocketPath
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: SocketControlSettings.baseDebugBundleIdentifier,
                isDebugBuild: true
            ) == "/tmp/cmux-debug.sock"
        )
    }
}
