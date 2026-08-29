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
        let supported = await speechConverter.supportedLanguages()
        var installed: [Language] = []

        for language in supported {
            if await speechConverter.resourceStatus(for: language) == .installed {
                installed.append(language)
            }
        }

        return installed.sorted {
            $0.displayName().localizedCaseInsensitiveCompare($1.displayName()) == .orderedAscending
        }
    }

    func speechResourceStatus(for language: Language) async -> SpeechResourceStatus {
        await speechConverter.resourceStatus(for: language)
    }

    func prepareSpeech(language: Language) async throws {
        try await speechConverter.prepare(language: language)
    }

    func translationResourceStatus(
        from source: Language,
        to target: Language
    ) async -> TranslationResourceStatus {
        await modelInventory.resourceStatus(from: source, to: target)
    }

    /// Translates app-provided copy with the same installed, offline provider.
    func translateText(
        _ text: String,
        from source: Language,
        to target: Language
    ) async throws -> String {
        guard source != target else { return text }

        switch await modelInventory.resourceStatus(from: source, to: target) {
        case .installed:
            return try await translator.translate(text, from: source, to: target)
        case .downloadable:
            throw TranslationBackendError.modelNotInstalled(
                source: source.displayName(),
                target: target.displayName()
            )
        case .unsupported:
            throw TranslationBackendError.unsupportedPair(
                source: source.displayName(),
                target: target.displayName()
            )
        }
    }

    func start(
        source: Language,
        target: Language
    ) async throws -> AsyncThrowingStream<VoiceTranslationResult, Error> {
        let status = await modelInventory.resourceStatus(from: source, to: target)
        switch status {
        case .installed:
            break
        case .downloadable:
            throw TranslationBackendError.modelNotInstalled(
                source: source.displayName(),
                target: target.displayName()
            )
        case .unsupported:
            throw TranslationBackendError.unsupportedPair(
                source: source.displayName(),
                target: target.displayName()
            )
        }

        let transcriptResults = try await speechConverter.start(language: source)
        let (results, continuation) = AsyncThrowingStream<VoiceTranslationResult, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(50)
        )

        relayTask = Task {
            do {
                for try await segment in transcriptResults {
                    let original = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !original.isEmpty else { continue }

                    if segment.isFinal {
                        let translated = try await translator.translate(
                            original,
                            from: source,
                            to: target
                        )
                        continuation.yield(
                            VoiceTranslationResult(
                                sourceLanguageText: original,
                                targetLanguageText: translated,
                                isFinal: true
                            )
                        )
                    } else {
                        continuation.yield(
                            VoiceTranslationResult(
                                sourceLanguageText: original,
                                targetLanguageText: nil,
                                isFinal: false
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
