import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionViewModel {
    private static let sourcePrompt = "Tap a microphone and start speaking."
    private static let targetPrompt = "Translation will appear here."
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
    private var languageSelectionTask: Task<Void, Never>?
    private var hasLoadedLanguages = false

    private(set) var state: State = .idle
    private(set) var installedSourceLanguages: [Language] = []
    private(set) var installedTargetLanguages: [Language] = []
    private(set) var isLoadingLanguages = false
    private(set) var sourceLanguageText = sourcePrompt
    private(set) var targetLanguageText = targetPrompt
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
        installedSourceLanguages = languages

        guard !languages.isEmpty else {
            isLoadingLanguages = false
            modelStatusText = "No on-device Speech models are installed."
            return
        }

        let deviceLanguage = preferredLanguage(in: languages)
        bottomLanguage = deviceLanguage

        await reloadInstalledTargets(for: deviceLanguage, preservingSelection: false)
        isLoadingLanguages = false

        await updateInterfacePrompts()
        await refreshTranslationModelStatus()
    }

    func select(_ language: Language, for side: Side) {
        guard state == .idle else { return }

        switch side {
        case .top:
            topLanguage = language
            resetConversationText()
            Task {
                await updateInterfacePrompts()
                await refreshTranslationModelStatus()
            }
        case .bottom:
            bottomLanguage = language
            topLanguage = nil
            installedTargetLanguages = []
            resetConversationText()
            languageSelectionTask?.cancel()
            languageSelectionTask = Task {
                isLoadingLanguages = true
                await reloadInstalledTargets(for: language, preservingSelection: false)
                guard !Task.isCancelled, bottomLanguage == language else { return }
                isLoadingLanguages = false
                await updateInterfacePrompts()
                await refreshTranslationModelStatus()
                languageSelectionTask = nil
            }
        }
    }

    func swapLanguages() {
        guard state == .idle else { return }
        guard let topLanguage, let bottomLanguage else { return }
        guard installedSourceLanguages.contains(topLanguage) else {
            modelStatusText = "The \(topLanguage.displayName()) Speech model is not installed."
            return
        }

        (self.topLanguage, self.bottomLanguage) = (bottomLanguage, topLanguage)
        resetConversationText()
        languageSelectionTask?.cancel()
        languageSelectionTask = Task {
            isLoadingLanguages = true
            await reloadInstalledTargets(for: topLanguage, preservingSelection: true)
            guard !Task.isCancelled, self.bottomLanguage == topLanguage else { return }
            isLoadingLanguages = false
            await updateInterfacePrompts()
            await refreshTranslationModelStatus()
            languageSelectionTask = nil
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

    func beginCapture() {
        guard state == .idle else { return }
        startCapture()
    }

    func endCapture() {
        switch state {
        case .preparing:
            cancelCapture()
        case .listening:
            finishCapture()
        case .idle, .finishing:
            break
        }
    }

    func cancelCapture() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        state = .idle

        Task { await pipeline.cancel() }
    }

    func languages(for side: Side) -> [Language] {
        side == .bottom ? installedSourceLanguages : installedTargetLanguages
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
                targetLanguageText = Self.targetPrompt

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
            modelStatusText = installedSourceLanguages.isEmpty
                ? "Install a Speech language in Settings."
                : "Select an installed offline language pair."
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
        targetLanguageText = Self.targetPrompt
    }

    private func reloadInstalledTargets(
        for source: Language,
        preservingSelection: Bool
    ) async {
        let targets = await pipeline.installedTranslationTargets(from: source)
        guard !Task.isCancelled, bottomLanguage == source else { return }

        installedTargetLanguages = targets
        if preservingSelection, let topLanguage, targets.contains(topLanguage) {
            return
        }

        let indonesian = language(matching: "id", in: targets)
        topLanguage = indonesian ?? targets.first
        if targets.isEmpty {
            modelStatusText = "No offline Translation models are installed for \(source.displayName())."
        }
    }

    private func updateInterfacePrompts() async {
        await updateSourcePrompt()
        await updateTargetPrompt()
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

    private func updateTargetPrompt() async {
        guard let selectedLanguage = topLanguage else {
            targetLanguageText = Self.targetPrompt
            return
        }

        let selectedCode = Locale(identifier: selectedLanguage.identifier).language.languageCode
        let englishCode = Locale(identifier: Self.english.identifier).language.languageCode
        guard selectedCode != englishCode else {
            if state == .idle, topLanguage == selectedLanguage {
                targetLanguageText = Self.targetPrompt
            }
            return
        }

        let localizedPrompt = try? await pipeline.translateText(
            Self.targetPrompt,
            from: Self.english,
            to: selectedLanguage
        )

        guard state == .idle, topLanguage == selectedLanguage else { return }
        targetLanguageText = localizedPrompt ?? Self.targetPrompt
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
