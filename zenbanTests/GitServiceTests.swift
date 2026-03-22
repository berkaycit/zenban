import Foundation
import Testing
@testable import zenban

struct GitServiceTests {
    @Test
    func createPRFailsOnMissingTokenWithoutReferencingGitHubCLI() async {
        do {
            _ = try await GitService.createPR(
                worktreePath: "/tmp/zenban-pr",
                config: PRConfig(cardTitle: "Card"),
                environment: [:]
            )
            Issue.record("Expected createPR to stop when no GitHub token is present.")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("GITHUB_TOKEN"))
            #expect(!message.localizedCaseInsensitiveContains("GitHub CLI"))
        }
    }

    @Test
    func generateCommitMessageReportsClaudeAsUnavailable() async {
        do {
            _ = try await GitService.generateCommitMessage(
                worktreePath: "/tmp/zenban-claude",
                claudeAvailable: false
            )
            Issue.record("Expected missing Claude availability to stop AI generation.")
        } catch {
            #expect(error.localizedDescription == GitError.claudeNotInstalled.localizedDescription)
        }
    }
}
