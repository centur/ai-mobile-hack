import Foundation

/// Converts microphone audio into two pipeline values: original and translated text.
actor VoiceTranslationPipeline {
    private let speechConverter: SpeechToTextConverter
    private let translator: any TextTranslating
    private let modelInventory: any TranslationModelInventorying
    private var relayTask: Task<Void, Never>?

    init(
        speechConverter: SpeechToTextConverter,
        translator: any TextTranslating,
        modelInventory: any TranslationModelInventorying
    ) {
        self.speechConverter = speechConverter
        self.translator = translator
        self.modelInventory = modelInventory
    }

    func supportedSpeechLanguages() async -> [Language] {
        await speechConverter.supportedLanguages()
    }

    /// Languages whose Speech assets are already installed on this device.
    func installedSpeechLanguages() async -> [Language] {
        await speechConverter.installedLanguages()
    }

    func speechResourceStatus(for language: Language) async -> SpeechResourceStatus {
        await speechConverter.resourceStatus(for: language)
    }

    func prepareSpeech(language: Language) async throws {
        try await speechConverter.prepare(language: language)
    }

    func removeSpeech(language: Language) async throws {
        try await speechConverter.remove(language: language)
    }

    func translationResourceStatus(
        from spokenLanguage: Language,
        to translatedToLanguage: Language
    ) async -> TranslationResourceStatus {
        await modelInventory.resourceStatus(
            from: spokenLanguage,
            to: translatedToLanguage
        )
    }

    func supportedTranslatedToLanguages(from spokenLanguage: Language) async -> [Language] {
        await modelInventory.supportedTranslatedToLanguages(from: spokenLanguage)
    }

    func installedTranslatedToLanguages(from spokenLanguage: Language) async -> [Language] {
        await modelInventory.installedTranslatedToLanguages(from: spokenLanguage)
    }

    /// Translates app-provided copy with the same installed, offline provider.
    func translateText(
        _ text: String,
        from spokenLanguage: Language,
        to translatedToLanguage: Language
    ) async throws -> String {
        guard spokenLanguage != translatedToLanguage else { return text }

        switch await modelInventory.resourceStatus(
            from: spokenLanguage,
            to: translatedToLanguage
        ) {
        case .installed:
            return try await translator.translate(
                text,
                from: spokenLanguage,
                to: translatedToLanguage
            )
        case .downloadable:
            throw TranslationBackendError.modelNotInstalled(
                spokenLanguage: spokenLanguage.displayName(),
                translatedToLanguage: translatedToLanguage.displayName()
            )
        case .unsupported:
            throw TranslationBackendError.unsupportedPair(
                spokenLanguage: spokenLanguage.displayName(),
                translatedToLanguage: translatedToLanguage.displayName()
            )
        }
    }

    func start(
        spokenLanguage: Language,
        translatedToLanguage: Language?
    ) async throws -> AsyncThrowingStream<VoiceTranslationResult, Error> {
        let transcriptResults = try await speechConverter.start(language: spokenLanguage)
        let (results, continuation) = AsyncThrowingStream<VoiceTranslationResult, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(50)
        )

        relayTask = Task {
            do {
                for try await segment in transcriptResults {
                    let original = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !original.isEmpty else { continue }

                    if segment.isFinal, let translatedToLanguage {
                        let translated = try? await translator.translate(
                            original,
                            from: spokenLanguage,
                            to: translatedToLanguage
                        )
                        continuation.yield(
                            VoiceTranslationResult(
                                spokenLanguageText: original,
                                translatedToLanguageText: translated,
                                isFinal: true
                            )
                        )
                    } else {
                        continuation.yield(
                            VoiceTranslationResult(
                                spokenLanguageText: original,
                                translatedToLanguageText: nil,
                                isFinal: segment.isFinal
                            )
                        )
                    }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            relayDidEnd()
        }

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancel() }
        }
        return results
    }

    func finish() async {
        await speechConverter.finish()
    }

    func cancel() async {
        relayTask?.cancel()
        relayTask = nil
        await speechConverter.cancel()
        await translator.cancel()
    }

    private func relayDidEnd() {
        relayTask = nil
    }
}
