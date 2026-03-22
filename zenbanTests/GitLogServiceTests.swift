import Foundation
import Testing
@testable import zenban

struct GitLogServiceTests {
    @Test
    func commitHistoryFailsFastWhenGitIsUnavailable() async {
        let service = GitLogService(gitPathProvider: { nil })

        do {
            _ = try await service.getCommitHistory(at: "/tmp/zenban-missing-git")
            Issue.record("Expected missing git to stop history loading.")
        } catch {
            #expect(
                error.localizedDescription == GitToolAvailabilityError.gitUnavailable.localizedDescription
            )
        }
    }

    @Test
    @MainActor
    func commitFilesUseInjectedRunnerOutput() async throws {
        let service = GitLogService(
            gitPathProvider: { "/usr/bin/git" },
            processRunner: { _, _, _ in
                ProcessResult(
                    exitCode: 0,
                    stdout: "12\t3\tSources/App.swift\n0\t1\tREADME.md\n",
                    stderr: ""
                )
            }
        )

        let files = try await service.getCommitFiles(hash: "abc123", at: "/tmp/repo")

        #expect(files.count == 2)
        #expect(files[0].path == "Sources/App.swift")
        #expect(files[0].additions == 12)
        #expect(files[0].deletions == 3)
        #expect(files[1].path == "README.md")
        #expect(files[1].additions == 0)
        #expect(files[1].deletions == 1)
    }
}
