import Foundation

protocol TextTranslating: Sendable {
    func translate(
        _ text: String,
        from spokenLanguage: Language,
        to translatedToLanguage: Language
    ) async throws -> String

    func cancel() async
}

protocol TranslationModelInventorying: Sendable {
    func supportedTranslatedToLanguages(from spokenLanguage: Language) async -> [Language]

    func installedTranslatedToLanguages(from spokenLanguage: Language) async -> [Language]

    func resourceStatus(
        from spokenLanguage: Language,
        to translatedToLanguage: Language
    ) async -> TranslationResourceStatus
}

nonisolated enum TranslationBackendError: LocalizedError, Sendable {
    case unsupportedPair(spokenLanguage: String, translatedToLanguage: String)
    case modelNotInstalled(spokenLanguage: String, translatedToLanguage: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPair(let spokenLanguage, let translatedToLanguage):
            "Translation from \(spokenLanguage) to \(translatedToLanguage) is not supported."
        case .modelNotInstalled(let spokenLanguage, let translatedToLanguage):
            "The offline translation model from \(spokenLanguage) to \(translatedToLanguage) is not installed."
        }
    }
}
