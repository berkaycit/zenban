import Testing
@testable import zenban

struct DependencyCheckServiceTests {
    @Test
    func dependencyListMatchesRuntimeSurfaceTools() {
        #expect(
            DependencyCheckService.Dependency.allCases.map(\.rawValue) == [
                "Git",
                "Claude Code CLI",
            ]
        )
    }

    @Test
    func checkAllReportsInjectedToolAvailability() async {
        let service = DependencyCheckService(
            gitPathProvider: { "/usr/bin/git" },
            claudePathProvider: { nil }
        )

        let status = await service.checkAll()

        #expect(status.git)
        #expect(!status.claude)
        #expect(status[.git])
        #expect(!status[.claude])
    }

    @Test
    func checkAllReportsMissingTools() async {
        let service = DependencyCheckService(
            gitPathProvider: { nil },
            claudePathProvider: { nil }
        )

        let status = await service.checkAll()

        #expect(!status.git)
        #expect(!status.claude)
    }

    @Test
    func dependencyDescriptionsExplainExternalScope() {
        #expect(
            DependencyCheckService.Dependency.git.description.contains("External on this Mac")
        )
        #expect(
            DependencyCheckService.Dependency.claude.description.contains("Optional")
        )
    }
}
