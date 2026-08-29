import Foundation

protocol TextTranslating: Sendable {
    func translate(
        _ text: String,
        from source: Language,
        to target: Language
    ) async throws -> String

    func cancel() async
}

protocol TranslationModelInventorying: Sendable {
    func resourceStatus(
        from source: Language,
        to target: Language
    ) async -> TranslationResourceStatus
}

nonisolated enum TranslationBackendError: LocalizedError, Sendable {
    case unsupportedPair(source: String, target: String)
    case modelNotInstalled(source: String, target: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPair(let source, let target):
            "Translation from \(source) to \(target) is not supported."
        case .modelNotInstalled(let source, let target):
            "The offline translation model from \(source) to \(target) is not installed."
        }
    }
}
