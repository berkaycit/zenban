import Foundation

/// Prompt templates for AI-powered features
enum PromptTemplate {
    case commitMessage
    case prDescription
    case codeReview

    var template: String {
        switch self {
        case .commitMessage:
            return Self.commitMessageTemplate
        case .prDescription:
            return Self.prDescriptionTemplate
        case .codeReview:
            return Self.codeReviewTemplate
        }
    }

    // MARK: - Templates

    private static let commitMessageTemplate = """
        Analyze the git diff provided via stdin and generate a commit message.

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

    private static let prDescriptionTemplate = """
        Analyze the git diff provided via stdin and generate a pull request description.

        Format your response as markdown with the following sections:
        ## Summary
        <Brief overview of what this PR does>

        ## Changes
        <Bullet list of specific changes>

        ## Testing
        <How to test these changes>

        Guidelines:
        - Be concise but thorough
        - Focus on the "why" not just the "what"
        - Mention any breaking changes
        """

    private static let codeReviewTemplate = """
        Review the code diff provided via stdin and provide feedback.

        Format your response as:
        ## Issues
        <List any bugs, security issues, or problems>

        ## Suggestions
        <List improvements or best practices>

        ## Positive
        <List things done well>

        Guidelines:
        - Be constructive and specific
        - Reference line numbers when possible
        - Prioritize issues by severity
        """
}
