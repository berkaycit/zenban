import Testing
@testable import zenban

struct ProcessEnvironmentTests {
    @Test
    func buildWithNodeSupportDisablesExternalBrowsers() {
        let environment = ProcessEnvironment.buildWithNodeSupport()
        #expect(environment["BROWSER"] == "none")
    }
}
