import Testing
@testable import zenban

struct DependencyCheckServiceTests {
    @Test
    func dependencyListContainsOnlyOptionalTools() {
        #expect(
            DependencyCheckService.Dependency.allCases.map(\.rawValue) == [
                "Homebrew",
                "GitHub CLI",
                "Claude Code CLI",
            ]
        )
    }

    @Test
    func statusTreatsMissingToolsAsOptional() {
        let status = DependencyCheckService.Status(
            homebrew: false,
            gh: false,
            claude: false
        )

        #expect(status.allRequired)
        #expect(status.hasMissingDependencies)
        #expect(status.hasMissingOptionalDependencies)
    }
}
