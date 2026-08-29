import Foundation

nonisolated enum TranslationResourceStatus: Equatable, Sendable {
    case unsupported
    case downloadable
    case installed
}

nonisolated struct TranslationModelResource: Identifiable, Equatable, Sendable {
    let language: Language
    let readiness: OfflineLanguagePairReadiness

    var id: String { language.id }
}

/// Every local resource required for either participant to speak a language.
nonisolated struct OfflineLanguagePairReadiness: Equatable, Sendable {
    let firstLanguage: Language
    let secondLanguage: Language
    let firstSpeech: SpeechResourceStatus
    let secondSpeech: SpeechResourceStatus
    let firstToSecondTranslation: TranslationResourceStatus
    let secondToFirstTranslation: TranslationResourceStatus

    var isFullyReady: Bool {
        firstSpeech == .installed
            && secondSpeech == .installed
            && firstToSecondTranslation == .installed
            && secondToFirstTranslation == .installed
    }

    var isBidirectionallySupported: Bool {
        firstSpeech != .unsupported
            && secondSpeech != .unsupported
            && firstToSecondTranslation != .unsupported
            && secondToFirstTranslation != .unsupported
    }

    func speechStatus(for language: Language) -> SpeechResourceStatus? {
        if language == firstLanguage { return firstSpeech }
        if language == secondLanguage { return secondSpeech }
        return nil
    }

    func translationStatus(
        from source: Language,
        to target: Language
    ) -> TranslationResourceStatus? {
        if source == firstLanguage, target == secondLanguage {
            return firstToSecondTranslation
        }
        if source == secondLanguage, target == firstLanguage {
            return secondToFirstTranslation
        }
        return nil
    }
}

nonisolated struct TranslationDownloadRequest: Equatable, Sendable {
    let source: Language
    let target: Language
}
