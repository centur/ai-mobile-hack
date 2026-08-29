import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionViewModel {
    static let demoTargetLanguage = Language(identifier: "id")

    enum State: Equatable {
        case idle
        case preparing
        case listening
        case finishing
    }

    private let pipeline: VoiceTranslationPipeline
    private var transcriptionTask: Task<Void, Never>?

    private(set) var state: State = .idle
    private(set) var sourceLanguageText = "Tap the microphone and start speaking."
    private(set) var targetLanguageText = "Indonesian translation will appear here."

    var isListening: Bool {
        state == .listening
    }

    init(pipeline: VoiceTranslationPipeline = SpeechBackend.makeAppleOnDevice()) {
        self.pipeline = pipeline
    }

    func toggleCapture() {
        switch state {
        case .idle:
            startCapture()
        case .preparing:
            cancelCapture()
        case .listening:
            finishCapture()
        case .finishing:
            break
        }
    }

    func cancelCapture() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .idle

        Task {
            await pipeline.cancel()
        }
    }

    private func startCapture() {
        state = .preparing
        sourceLanguageText = "Preparing speech recognition…"
        targetLanguageText = "Checking installed Indonesian translation models…"

        transcriptionTask = Task {
            do {
                let language = try await preferredSupportedLanguage()
                let status = await pipeline.speechResourceStatus(for: language)

                if status != .installed {
                    sourceLanguageText = "Downloading \(language.displayName()) speech model…"
                    try await pipeline.prepareSpeech(language: language)
                }

                try Task.checkCancellation()
                let translationStatus = await pipeline.translationResourceStatus(
                    from: language,
                    to: Self.demoTargetLanguage
                )
                switch translationStatus {
                case .installed:
                    targetLanguageText = "Indonesian model is installed."
                case .downloadable:
                    targetLanguageText = "Indonesian model is available but not installed for \(language.displayName())."
                case .unsupported:
                    targetLanguageText = "Indonesian translation is unsupported for \(language.displayName())."
                }

                let results = try await pipeline.start(
                    source: language,
                    target: Self.demoTargetLanguage
                )
                state = .listening
                sourceLanguageText = "Listening…"

                for try await result in results {
                    try Task.checkCancellation()
                    sourceLanguageText = result.sourceLanguageText
                    if let translation = result.targetLanguageText {
                        targetLanguageText = translation
                    }
                }

                state = .idle
                transcriptionTask = nil
            } catch is CancellationError {
                state = .idle
                transcriptionTask = nil
            } catch {
                targetLanguageText = error.localizedDescription
                state = .idle
                transcriptionTask = nil
                await pipeline.cancel()
            }
        }
    }

    private func finishCapture() {
        state = .finishing

        Task {
            await pipeline.finish()
        }
    }

    private func preferredSupportedLanguage() async throws -> Language {
        let supported = await pipeline.supportedSpeechLanguages()
        guard !supported.isEmpty else {
            throw SpeechBackendError.speechTranscriberUnavailable
        }

        for preferredIdentifier in Locale.preferredLanguages {
            if let exactMatch = supported.first(where: {
                $0.identifier.caseInsensitiveCompare(preferredIdentifier) == .orderedSame
            }) {
                return exactMatch
            }

            let preferredCode = Locale(identifier: preferredIdentifier).language.languageCode
            if let languageMatch = supported.first(where: {
                Locale(identifier: $0.identifier).language.languageCode == preferredCode
            }) {
                return languageMatch
            }
        }

        return supported[0]
    }
}
