import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionViewModel {
    private static let sourcePrompt = "Tap a microphone and start speaking."
    private static let english = Language(identifier: "en")

    nonisolated enum Side: Equatable, Sendable {
        case top
        case bottom

    }

    enum State: Equatable {
        case idle
        case preparing
        case listening
        case finishing
    }

    private let pipeline: VoiceTranslationPipeline
    private var transcriptionTask: Task<Void, Never>?
    private var hasLoadedLanguages = false

    private(set) var state: State = .idle
    private(set) var installedLanguages: [Language] = []
    private(set) var isLoadingLanguages = false
    private(set) var sourceLanguageText = sourcePrompt
    private(set) var targetLanguageText = "Translation will appear here."
    private(set) var modelStatusText = "Loading installed languages…"

    var topLanguage: Language?
    var bottomLanguage: Language?

    init(pipeline: VoiceTranslationPipeline = SpeechBackend.makeAppleOnDevice()) {
        self.pipeline = pipeline
    }

    func loadInstalledLanguages() async {
        guard !hasLoadedLanguages else { return }
        hasLoadedLanguages = true
        isLoadingLanguages = true
        modelStatusText = "Checking installed Speech models…"

        let languages = await pipeline.installedSpeechLanguages()
        installedLanguages = languages
        isLoadingLanguages = false

        guard !languages.isEmpty else {
            modelStatusText = "No on-device Speech models are installed."
            return
        }

        let deviceLanguage = preferredLanguage(in: languages)
        bottomLanguage = deviceLanguage

        let indonesian = language(matching: "id", in: languages)
        topLanguage = if indonesian != deviceLanguage {
            indonesian ?? languages.first(where: { $0 != deviceLanguage })
        } else {
            languages.first(where: { $0 != deviceLanguage })
        }

        await updateSourcePrompt()
        await refreshTranslationModelStatus()
    }

    func select(_ language: Language, for side: Side) {
        guard state == .idle else { return }

        switch side {
        case .top:
            topLanguage = language
        case .bottom:
            bottomLanguage = language
        }

        resetConversationText()
        Task {
            await updateSourcePrompt()
            await refreshTranslationModelStatus()
        }
    }

    func swapLanguages() {
        guard state == .idle else { return }
        (topLanguage, bottomLanguage) = (bottomLanguage, topLanguage)
        resetConversationText()
        Task {
            await updateSourcePrompt()
            await refreshTranslationModelStatus()
        }
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

        Task { await pipeline.cancel() }
    }

    func text(for side: Side) -> String {
        side == .top ? targetLanguageText : sourceLanguageText
    }

    var isMicrophoneActive: Bool {
        state != .idle
    }

    var isMicrophoneEnabled: Bool {
        guard bottomLanguage != nil, topLanguage != nil else { return false }
        switch state {
        case .idle, .preparing, .listening:
            return true
        case .finishing:
            return false
        }
    }

    private func startCapture() {
        guard let source = bottomLanguage,
              let target = topLanguage else {
            modelStatusText = "Select two installed languages first."
            return
        }
        guard source != target else {
            modelStatusText = "Source and target languages must be different."
            return
        }

        state = .preparing
        sourceLanguageText = "Preparing \(source.displayName()) speech recognition…"
        targetLanguageText = "Checking \(target.displayName()) translation model…"

        transcriptionTask = Task {
            do {
                guard await pipeline.speechResourceStatus(for: source) == .installed else {
                    throw SpeechBackendError.resourceNotInstalled(source.identifier)
                }

                let translationStatus = await pipeline.translationResourceStatus(
                    from: source,
                    to: target
                )
                switch translationStatus {
                case .installed:
                    modelStatusText = "\(source.displayName()) → \(target.displayName()) is ready offline."
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

                try Task.checkCancellation()
                let results = try await pipeline.start(source: source, target: target)
                state = .listening
                sourceLanguageText = "Listening in \(source.displayName())…"
                targetLanguageText = "Translation will appear here."

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
                modelStatusText = error.localizedDescription
                state = .idle
                transcriptionTask = nil
                await pipeline.cancel()
            }
        }
    }

    private func finishCapture() {
        state = .finishing
        Task { await pipeline.finish() }
    }

    private func refreshTranslationModelStatus() async {
        guard let topLanguage, let bottomLanguage else {
            modelStatusText = installedLanguages.count < 2
                ? "Install at least two Speech languages in Settings."
                : "Select two installed languages."
            return
        }
        guard topLanguage != bottomLanguage else {
            modelStatusText = "Source and target languages must be different."
            return
        }

        let bottomToTop = await pipeline.translationResourceStatus(
            from: bottomLanguage,
            to: topLanguage
        )

        switch bottomToTop {
        case .installed:
            modelStatusText = "\(bottomLanguage.displayName()) → \(topLanguage.displayName()) is ready offline."
        case .downloadable:
            modelStatusText = "The source-to-target translation model is not downloaded."
        case .unsupported:
            modelStatusText = "The selected source-to-target translation is unsupported."
        }
    }

    private func resetConversationText() {
        sourceLanguageText = Self.sourcePrompt
        targetLanguageText = "Translation will appear here."
    }

    private func updateSourcePrompt() async {
        guard let selectedLanguage = bottomLanguage else {
            sourceLanguageText = Self.sourcePrompt
            return
        }

        let selectedCode = Locale(identifier: selectedLanguage.identifier).language.languageCode
        let englishCode = Locale(identifier: Self.english.identifier).language.languageCode
        guard selectedCode != englishCode else {
            if state == .idle, bottomLanguage == selectedLanguage {
                sourceLanguageText = Self.sourcePrompt
            }
            return
        }

        let localizedPrompt = try? await pipeline.translateText(
            Self.sourcePrompt,
            from: Self.english,
            to: selectedLanguage
        )

        guard state == .idle, bottomLanguage == selectedLanguage else { return }
        sourceLanguageText = localizedPrompt ?? Self.sourcePrompt
    }

    private func preferredLanguage(in languages: [Language]) -> Language {
        for identifier in Locale.preferredLanguages {
            if let match = language(matching: identifier, in: languages) {
                return match
            }
        }
        return languages[0]
    }

    private func language(matching identifier: String, in languages: [Language]) -> Language? {
        if let exact = languages.first(where: {
            $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return exact
        }

        let desiredCode = Locale(identifier: identifier).language.languageCode
        return languages.first {
            Locale(identifier: $0.identifier).language.languageCode == desiredCode
        }
    }
}
