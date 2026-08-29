import Foundation
import Translation

nonisolated struct AppleTextTranslator: TextTranslating {
    nonisolated func translate(
        _ text: String,
        from spokenLanguage: Language,
        to translatedToLanguage: Language
    ) async throws -> String {
        let spokenLocaleLanguage = Locale.Language(identifier: spokenLanguage.identifier)
        let translatedToLocaleLanguage = Locale.Language(
            identifier: translatedToLanguage.identifier
        )
        let session = TranslationSession(
            installedSource: spokenLocaleLanguage,
            target: translatedToLocaleLanguage,
            preferredStrategy: .lowLatency
        )
        let response = try await session.translate(text)
        return response.targetText
    }

    nonisolated func cancel() async {}
}
