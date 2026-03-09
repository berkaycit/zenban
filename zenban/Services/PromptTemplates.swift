import Foundation

/// Prompt templates for AI-powered features
enum PromptTemplate {
    case commitMessage

    var template: String {
        switch self {
        case .commitMessage:
            return Self.commitMessageTemplate
        }
    }

    // MARK: - Templates

    private static let commitMessageTemplate = """
        Analyze the git changes provided via stdin and generate a commit message.

        The input may be:
        1. A full unified diff, OR
        2. A summarized format with file list and partial snippets (for large changesets)

        For summarized input, focus on the overall change pattern across files.

        Format your response EXACTLY as:
        SUMMARY: <one line summary, max 72 chars, imperative mood>
        DESCRIPTION: <detailed description, can be multiple lines>

        Guidelines:
        - Summary should be concise and describe WHAT changed
        - Description should explain WHY and provide context
        - Use imperative mood ("Add feature" not "Added feature")
        - Be specific about the changes
        - Do not include the word "SUMMARY" or "DESCRIPTION" in the actual content
        """
}
