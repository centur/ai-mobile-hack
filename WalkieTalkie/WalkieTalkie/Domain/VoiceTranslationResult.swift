import Foundation

/// One pipeline update containing the source transcript and its translation.
nonisolated struct VoiceTranslationResult: Equatable, Sendable {
    let sourceLanguageText: String
    let targetLanguageText: String?
    let isFinal: Bool
}
