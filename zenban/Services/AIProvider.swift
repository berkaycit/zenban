import Foundation

// MARK: - AI Provider Protocol

/// Protocol for AI service providers (Claude, OpenAI, local LLMs, etc.)
protocol AIProvider {
    /// Whether this provider is available (installed, configured, etc.)
    static var isAvailable: Bool { get }

    /// Human-readable name of the provider
    static var providerName: String { get }

    /// Generate a response from the AI provider
    /// - Parameters:
    ///   - prompt: The prompt/instructions for the AI
    ///   - context: Additional context (e.g., code diff) passed via stdin
    ///   - workingDirectory: The working directory for the operation
    ///   - config: Configuration options for the generation
    /// - Returns: The AI-generated response as a string
    static func generate(
        prompt: String,
        context: String,
        workingDirectory: String,
        config: AIProviderConfig
    ) async throws -> String
}

// MARK: - Configuration

struct AIProviderConfig {
    var timeout: TimeInterval
    var maxTokens: Int?

    init(timeout: TimeInterval = 60, maxTokens: Int? = nil) {
        self.timeout = timeout
        self.maxTokens = maxTokens
    }

    static let `default` = AIProviderConfig()
}

// MARK: - Errors

enum AIProviderError: Error, LocalizedError {
    case providerNotAvailable(String)
    case executionFailed(String)
    case timeout
    case invalidResponse(String)
    case noContentToAnalyze

    var errorDescription: String? {
        switch self {
        case .providerNotAvailable(let name):
            return "\(name) is not installed or configured"
        case .executionFailed(let msg):
            return "AI generation failed: \(msg)"
        case .timeout:
            return "AI generation timed out"
        case .invalidResponse(let msg):
            return "Invalid AI response: \(msg)"
        case .noContentToAnalyze:
            return "No content to analyze"
        }
    }
}
