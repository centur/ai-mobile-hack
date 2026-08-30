import Foundation

/// Converts microphone audio into two pipeline values: original and translated text.
actor VoiceTranslationPipeline {
    private struct TranscriptPart: Sendable {
        let start: TimeInterval
        let duration: TimeInterval
        let text: String

        var end: TimeInterval { start + duration }
    }

    private struct TranslationPart: Sendable {
        let start: TimeInterval
        let duration: TimeInterval
        let sourceText: String
        let translatedText: String

        var timing: TranscriptPart {
            TranscriptPart(start: start, duration: duration, text: translatedText)
        }
    }

    private let speechConverter: SpeechToTextConverter
    private let translator: any TextTranslating
    private let modelInventory: any TranslationModelInventorying
    private var relayTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var latestTranscriptText = ""
    private var lastTranslatedText = ""
    private var accumulatedTranslatedText = ""
    private var accumulatedSpokenText = ""
    private var previousTranscriptText = ""
    private var transcriptParts: [TranscriptPart] = []
    private var translationParts: [TranslationPart] = []

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

    func offlineReadiness(
        between firstLanguage: Language,
        and secondLanguage: Language
    ) async -> OfflineLanguagePairReadiness {
        let firstSpeech = await speechConverter.resourceStatus(for: firstLanguage)
        let secondSpeech = await speechConverter.resourceStatus(for: secondLanguage)
        let firstToSecond = await modelInventory.resourceStatus(
            from: firstLanguage,
            to: secondLanguage
        )
        let secondToFirst = await modelInventory.resourceStatus(
            from: secondLanguage,
            to: firstLanguage
        )

        return OfflineLanguagePairReadiness(
            firstLanguage: firstLanguage,
            secondLanguage: secondLanguage,
            firstSpeech: firstSpeech,
            secondSpeech: secondSpeech,
            firstToSecondTranslation: firstToSecond,
            secondToFirstTranslation: secondToFirst
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
        translatedToLanguage: Language?,
        silenceDuration: Duration
    ) async throws -> AsyncThrowingStream<VoiceTranslationResult, Error> {
        let transcriptResults = try await speechConverter.start(language: spokenLanguage)
        let (results, continuation) = AsyncThrowingStream<VoiceTranslationResult, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(50)
        )
        latestTranscriptText = ""
        lastTranslatedText = ""
        accumulatedTranslatedText = ""
        accumulatedSpokenText = ""
        previousTranscriptText = ""
        transcriptParts = []
        translationParts = []
        silenceTask?.cancel()
        silenceTask = nil

        relayTask = Task {
            do {
                for try await segment in transcriptResults {
                    let original = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !original.isEmpty else { continue }
                    latestTranscriptText = original
                    silenceTask?.cancel()
                    accumulateSpokenText(original, segment: segment)

                    continuation.yield(
                        VoiceTranslationResult(
                            spokenLanguageText: accumulatedSpokenText,
                            translatedToLanguageText: nil,
                            isFinal: segment.isFinal
                        )
                    )

                    guard let translatedToLanguage else { continue }
                    if segment.isFinal {
                        await translateLatestTranscript(
                            original,
                            segment: segment,
                            from: spokenLanguage,
                            to: translatedToLanguage,
                            continuation: continuation
                        )
                    } else {
                        scheduleTranslationAfterSilence(
                            original,
                            segment: segment,
                            from: spokenLanguage,
                            to: translatedToLanguage,
                            silenceDuration: silenceDuration,
                            continuation: continuation
                        )
                    }
                }
                silenceTask?.cancel()
                silenceTask = nil
                continuation.finish()
            } catch is CancellationError {
                silenceTask?.cancel()
                silenceTask = nil
                continuation.finish()
            } catch {
                silenceTask?.cancel()
                silenceTask = nil
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
        silenceTask?.cancel()
        silenceTask = nil
        await speechConverter.finish()
    }

    func cancel() async {
        silenceTask?.cancel()
        silenceTask = nil
        relayTask?.cancel()
        relayTask = nil
        await speechConverter.cancel()
        await translator.cancel()
    }

    private func relayDidEnd() {
        relayTask = nil
    }

    private func scheduleTranslationAfterSilence(
        _ text: String,
        segment: TranscriptSegment,
        from spokenLanguage: Language,
        to translatedToLanguage: Language,
        silenceDuration: Duration,
        continuation: AsyncThrowingStream<VoiceTranslationResult, Error>.Continuation
    ) {
        silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: silenceDuration)
                guard !Task.isCancelled else { return }
                await self?.translateLatestTranscript(
                    text,
                    segment: segment,
                    from: spokenLanguage,
                    to: translatedToLanguage,
                    continuation: continuation
                )
            } catch is CancellationError {
                // A newer speech result restarted the silence interval.
            } catch {
                // Sleeping has no other expected failure mode.
            }
        }
    }

    private func translateLatestTranscript(
        _ text: String,
        segment: TranscriptSegment,
        from spokenLanguage: Language,
        to translatedToLanguage: Language,
        continuation: AsyncThrowingStream<VoiceTranslationResult, Error>.Continuation
    ) async {
        guard latestTranscriptText == text else { return }
        if let start = segment.startTime {
            if translationParts.contains(where: {
                abs($0.start - start) < 0.15 && $0.sourceText == text
            }) {
                return
            }
        } else if lastTranslatedText == text {
            return
        }

        let translated = try? await translator.translate(
            text,
            from: spokenLanguage,
            to: translatedToLanguage
        )
        guard !Task.isCancelled,
              latestTranscriptText == text,
              lastTranslatedText != text,
              let translated else { return }

        mergeTranslatedText(translated, sourceText: text, segment: segment)
        continuation.yield(
            VoiceTranslationResult(
                spokenLanguageText: accumulatedSpokenText,
                translatedToLanguageText: accumulatedTranslatedText,
                isFinal: true
            )
        )
    }

    private func mergeTranslatedText(
        _ translatedText: String,
        sourceText: String,
        segment: TranscriptSegment
    ) {
        defer { lastTranslatedText = sourceText }

        if let start = segment.startTime,
           let duration = segment.duration,
           start.isFinite,
           duration.isFinite {
            let newPart = TranslationPart(
                start: start,
                duration: max(duration, 0),
                sourceText: sourceText,
                translatedText: translatedText
            )
            translationParts.removeAll {
                representsSameAudio($0.timing, newPart.timing)
            }
            translationParts.append(newPart)
            translationParts.sort { $0.start < $1.start }
            accumulatedTranslatedText = translationParts
                .map(\.translatedText)
                .joined(separator: "\n")
            return
        }

        if accumulatedTranslatedText.isEmpty {
            accumulatedTranslatedText = translatedText
        } else if sourceText.hasPrefix(lastTranslatedText)
                    || lastTranslatedText.hasPrefix(sourceText) {
            accumulatedTranslatedText = translatedText
        } else {
            accumulatedTranslatedText += "\n" + translatedText
        }
    }

    private func accumulateSpokenText(
        _ text: String,
        segment: TranscriptSegment
    ) {
        if let start = segment.startTime,
           let duration = segment.duration,
           start.isFinite,
           duration.isFinite {
            let newPart = TranscriptPart(
                start: start,
                duration: max(duration, 0),
                text: text
            )

            transcriptParts.removeAll { existingPart in
                representsSameAudio(existingPart, newPart)
            }
            transcriptParts.append(newPart)
            transcriptParts.sort { $0.start < $1.start }
            accumulatedSpokenText = transcriptParts
                .map(\.text)
                .joined(separator: "\n")
            previousTranscriptText = text
            return
        }

        guard !previousTranscriptText.isEmpty else {
            accumulatedSpokenText = text
            previousTranscriptText = text
            return
        }

        if text == previousTranscriptText {
            return
        }

        if text.hasPrefix(previousTranscriptText)
            || previousTranscriptText.hasPrefix(text) {
            accumulatedSpokenText.removeLast(previousTranscriptText.count)
            accumulatedSpokenText.append(text)
        } else {
            accumulatedSpokenText.append("\n")
            accumulatedSpokenText.append(text)
        }
        previousTranscriptText = text
    }

    private func representsSameAudio(
        _ first: TranscriptPart,
        _ second: TranscriptPart
    ) -> Bool {
        if abs(first.start - second.start) < 0.15 {
            return true
        }

        let overlap = max(0, min(first.end, second.end) - max(first.start, second.start))
        let shorterDuration = min(first.duration, second.duration)
        return shorterDuration > 0 && overlap / shorterDuration >= 0.8
    }
}
