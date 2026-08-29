import Foundation

/// One pipeline update containing spoken text and its translation.
nonisolated struct VoiceTranslationResult: Equatable, Sendable {
    let spokenLanguageText: String
    let translatedToLanguageText: String?
    let isFinal: Bool
}
