import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionViewModel {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case finishing
    }

    private let converter: SpeechToTextConverter
    private var transcriptionTask: Task<Void, Never>?

    private(set) var state: State = .idle
    private(set) var transcript = "Tap the microphone and start speaking."

    var isListening: Bool {
        state == .listening
    }

    init(converter: SpeechToTextConverter = SpeechBackend.makeAppleOnDevice()) {
        self.converter = converter
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
            await converter.cancel()
        }
    }

    private func startCapture() {
        state = .preparing
        transcript = "Preparing speech recognition…"

        transcriptionTask = Task {
            do {
                let language = try await preferredSupportedLanguage()
                let status = await converter.resourceStatus(for: language)

                if status != .installed {
                    transcript = "Downloading \(language.displayName())…"
                    try await converter.prepare(language: language)
                }

                try Task.checkCancellation()
                let results = try await converter.start(language: language)
                state = .listening
                transcript = "Listening…"

                for try await segment in results {
                    try Task.checkCancellation()
                    if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        transcript = segment.text
                    }
                }

                state = .idle
                transcriptionTask = nil
            } catch is CancellationError {
                state = .idle
                transcriptionTask = nil
            } catch {
                transcript = error.localizedDescription
                state = .idle
                transcriptionTask = nil
                await converter.cancel()
            }
        }
    }

    private func finishCapture() {
        state = .finishing

        Task {
            await converter.finish()
        }
    }

    private func preferredSupportedLanguage() async throws -> Language {
        let supported = await converter.supportedLanguages()
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
