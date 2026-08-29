import Foundation
import Translation

nonisolated struct AppleTextTranslator: TextTranslating {
    nonisolated func translate(
        _ text: String,
        from source: Language,
        to target: Language
    ) async throws -> String {
        let sourceLanguage = Locale.Language(identifier: source.identifier)
        let targetLanguage = Locale.Language(identifier: target.identifier)
        let session = TranslationSession(
            installedSource: sourceLanguage,
            target: targetLanguage,
            preferredStrategy: .lowLatency
        )
        let response = try await session.translate(text)
        return response.targetText
    }

    nonisolated func cancel() async {}
}
