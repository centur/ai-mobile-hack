import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionViewModel {
    private static let spokenPrompt = "Tap a microphone and start speaking."
    private static let translatedToPrompt = "Translation will appear here."
    private static let english = Language(identifier: "en")

    nonisolated enum LanguageRole: Equatable, Sendable {
        case translatedTo
        case spoken
    }

    enum State: Equatable {
        case idle
        case preparing
        case listening
        case finishing
    }

    private let pipeline: VoiceTranslationPipeline
    private var transcriptionTask: Task<Void, Never>?
    private var captureTransitionTask: Task<Void, Never>?
    private var captureID: UUID?
    private var languageSelectionTask: Task<Void, Never>?
    private var hasLoadedLanguages = false

    private(set) var state: State = .idle
    private(set) var installedSpokenLanguages: [Language] = []
    private(set) var installedTranslatedToLanguages: [Language] = []
    private(set) var speechModels: [SpeechModelResource] = []
    private(set) var isLoadingLanguages = false
    private(set) var isLoadingSpeechModels = false
    private(set) var speechModelOperationLanguage: Language?
    private(set) var speechModelManagerMessage: String?
    private(set) var spokenLanguageText = spokenPrompt
    private(set) var translatedToLanguageText = translatedToPrompt
    private(set) var modelStatusText = "Loading installed languages…"
    private(set) var activeMicrophoneRole: LanguageRole?

    var translatedToLanguage: Language?
    var spokenLanguage: Language?

    init(pipeline: VoiceTranslationPipeline = SpeechBackend.makeAppleOnDevice()) {
        self.pipeline = pipeline
    }

    func loadInstalledLanguages() async {
        guard !hasLoadedLanguages else { return }
        hasLoadedLanguages = true
        isLoadingLanguages = true
        modelStatusText = "Checking installed Speech models…"

        let languages = await pipeline.installedSpeechLanguages()
        installedSpokenLanguages = languages

        guard !languages.isEmpty else {
            isLoadingLanguages = false
            modelStatusText = "No on-device Speech models are installed."
            return
        }

        let deviceLanguage = preferredLanguage(in: languages)
        spokenLanguage = deviceLanguage

        await reloadInstalledTranslatedToLanguages(
            for: deviceLanguage,
            preservingSelection: false
        )
        isLoadingLanguages = false

        await updateInterfacePrompts()
        await refreshTranslationModelStatus()
    }

    func loadSpeechModels() async {
        guard speechModelOperationLanguage == nil else { return }
        isLoadingSpeechModels = true
        speechModelManagerMessage = nil
        await refreshSpeechModels()
        isLoadingSpeechModels = false
    }

    func downloadSpeechModel(_ language: Language) async {
        guard state == .idle, speechModelOperationLanguage == nil else { return }
        speechModelOperationLanguage = language
        updateSpeechModel(language, status: .downloading)

        do {
            try await pipeline.prepareSpeech(language: language)
            await refreshSpeechModels()
            await refreshInstalledLanguageSelections()
        } catch {
            speechModelManagerMessage = error.localizedDescription
            await refreshSpeechModels()
        }

        speechModelOperationLanguage = nil
    }

    func removeSpeechModel(_ language: Language) async {
        guard state == .idle, speechModelOperationLanguage == nil else { return }
        speechModelOperationLanguage = language

        do {
            try await pipeline.removeSpeech(language: language)
            speechModelManagerMessage = "\(language.displayName()) was released. iOS will remove the model when it is no longer used by the system or other apps."
            await refreshSpeechModels()
            await refreshInstalledLanguageSelections()
        } catch {
            speechModelManagerMessage = error.localizedDescription
        }

        speechModelOperationLanguage = nil
    }

    func clearSpeechModelManagerMessage() {
        speechModelManagerMessage = nil
    }

    func select(_ language: Language, for role: LanguageRole) {
        guard state == .idle else { return }

        switch role {
        case .translatedTo:
            translatedToLanguage = language
            resetConversationText()
            Task {
                await updateInterfacePrompts()
                await refreshTranslationModelStatus()
            }
        case .spoken:
            spokenLanguage = language
            translatedToLanguage = nil
            installedTranslatedToLanguages = []
            resetConversationText()
            languageSelectionTask?.cancel()
            languageSelectionTask = Task {
                isLoadingLanguages = true
                await reloadInstalledTranslatedToLanguages(
                    for: language,
                    preservingSelection: false
                )
                guard !Task.isCancelled, spokenLanguage == language else { return }
                isLoadingLanguages = false
                await updateInterfacePrompts()
                await refreshTranslationModelStatus()
                languageSelectionTask = nil
            }
        }
    }

    func swapLanguages() {
        guard state == .idle else { return }
        guard let translatedToLanguage, let spokenLanguage else { return }
        guard installedSpokenLanguages.contains(translatedToLanguage) else {
            modelStatusText = "The \(translatedToLanguage.displayName()) Speech model is not installed."
            return
        }

        (self.translatedToLanguage, self.spokenLanguage) = (
            spokenLanguage,
            translatedToLanguage
        )
        resetConversationText()
        languageSelectionTask?.cancel()
        languageSelectionTask = Task {
            isLoadingLanguages = true
            await reloadInstalledTranslatedToLanguages(
                for: translatedToLanguage,
                preservingSelection: true
            )
            guard !Task.isCancelled,
                  self.spokenLanguage == translatedToLanguage else { return }
            isLoadingLanguages = false
            await updateInterfacePrompts()
            await refreshTranslationModelStatus()
            languageSelectionTask = nil
        }
    }

    func toggleCapture(for role: LanguageRole) {
        switch state {
        case .idle:
            startCapture(for: role)
        case .preparing:
            if activeMicrophoneRole == role {
                cancelCapture()
            } else {
                switchCapture(to: role, finalizingCurrentCapture: false)
            }
        case .listening:
            if activeMicrophoneRole == role {
                finishCapture()
            } else {
                switchCapture(to: role, finalizingCurrentCapture: true)
            }
        case .finishing:
            break
        }
    }

    func cancelCapture() {
        captureTransitionTask?.cancel()
        captureTransitionTask = nil
        captureID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeMicrophoneRole = nil
        state = .idle

        Task { await pipeline.cancel() }
    }

    func languages(for role: LanguageRole) -> [Language] {
        role == .spoken ? installedSpokenLanguages : installedTranslatedToLanguages
    }

    func text(for role: LanguageRole) -> String {
        role == .translatedTo ? translatedToLanguageText : spokenLanguageText
    }

    func isMicrophoneActive(for role: LanguageRole) -> Bool {
        activeMicrophoneRole == role && (state == .preparing || state == .listening)
    }

    func isMicrophoneEnabled(for role: LanguageRole) -> Bool {
        guard language(for: role) != nil else { return false }
        if role == .translatedTo, language(for: role.opposite) == nil { return false }
        switch state {
        case .idle, .preparing, .listening:
            return true
        case .finishing:
            return false
        }
    }

    private func startCapture(for role: LanguageRole) {
        guard let captureSpokenLanguage = language(for: role) else {
            modelStatusText = "Select an installed speech language first."
            return
        }
        let captureTranslatedToLanguage = language(for: role.opposite)
        guard captureTranslatedToLanguage != captureSpokenLanguage else {
            modelStatusText = "Spoken and translated-to languages must be different."
            return
        }

        state = .preparing
        activeMicrophoneRole = role
        setText(
            "Preparing \(captureSpokenLanguage.displayName()) speech recognition…",
            for: role
        )
        if let captureTranslatedToLanguage {
            setText(
                "Checking \(captureTranslatedToLanguage.displayName()) translation model…",
                for: role.opposite
            )
        }
        let captureID = UUID()
        self.captureID = captureID

        transcriptionTask = Task {
            do {
                let speechResourceStatus = await pipeline.speechResourceStatus(for: captureSpokenLanguage)
                
                guard speechResourceStatus == .installed else {
                    throw SpeechBackendError.resourceNotInstalled(
                        captureSpokenLanguage.identifier
                    )
                }

                var translationLanguage: Language?
                if let captureTranslatedToLanguage,
                   await pipeline.translationResourceStatus(
                       from: captureSpokenLanguage,
                       to: captureTranslatedToLanguage
                   ) == .installed {
                    translationLanguage = captureTranslatedToLanguage
                }

                try Task.checkCancellation()
                let results = try await pipeline.start(
                    spokenLanguage: captureSpokenLanguage,
                    translatedToLanguage: translationLanguage
                )
                guard self.captureID == captureID else { return }
                state = .listening
                modelStatusText = "Listening in \(captureSpokenLanguage.displayName())…"
                setText("Listening in \(captureSpokenLanguage.displayName())…", for: role)
                if translationLanguage != nil {
                    setText(Self.translatedToPrompt, for: role.opposite)
                }

                for try await result in results {
                    try Task.checkCancellation()
                    guard self.captureID == captureID else { return }
                    setText(result.spokenLanguageText, for: role)
                    if let translation = result.translatedToLanguageText {
                        setText(translation, for: role.opposite)
                    }
                }

                guard self.captureID == captureID else { return }
                state = .idle
                activeMicrophoneRole = nil
                self.captureID = nil
                transcriptionTask = nil
            } catch is CancellationError {
                guard self.captureID == captureID else { return }
                state = .idle
                activeMicrophoneRole = nil
                self.captureID = nil
                transcriptionTask = nil
            } catch {
                guard self.captureID == captureID else { return }
                setText(error.localizedDescription, for: role)
                modelStatusText = error.localizedDescription
                state = .idle
                activeMicrophoneRole = nil
                self.captureID = nil
                transcriptionTask = nil
                await pipeline.cancel()
            }
        }
    }

    private func finishCapture() {
        state = .finishing
        activeMicrophoneRole = nil
        Task { await pipeline.finish() }
    }

    private func switchCapture(
        to role: LanguageRole,
        finalizingCurrentCapture: Bool
    ) {
        let previousTask = transcriptionTask
        activeMicrophoneRole = nil
        state = .finishing

        captureTransitionTask?.cancel()
        captureTransitionTask = Task {
            if finalizingCurrentCapture {
                await pipeline.finish()
            } else {
                captureID = nil
                previousTask?.cancel()
                transcriptionTask = nil
                await pipeline.cancel()
            }
            await previousTask?.value
            guard !Task.isCancelled else { return }

            state = .idle
            captureTransitionTask = nil
            startCapture(for: role)
        }
    }

    private func refreshTranslationModelStatus() async {
        guard let translatedToLanguage, let spokenLanguage else {
            modelStatusText = installedSpokenLanguages.isEmpty
                ? "Install a Speech language in Settings."
                : "Select an installed offline language pair."
            return
        }
        guard translatedToLanguage != spokenLanguage else {
            modelStatusText = "Spoken and translated-to languages must be different."
            return
        }

        let spokenToTranslated = await pipeline.translationResourceStatus(
            from: spokenLanguage,
            to: translatedToLanguage
        )

        switch spokenToTranslated {
        case .installed:
            modelStatusText = "\(spokenLanguage.displayName()) → \(translatedToLanguage.displayName()) is ready offline."
        case .downloadable:
            modelStatusText = "The spoken-to-translated translation model is not downloaded."
        case .unsupported:
            modelStatusText = "The selected spoken-to-translated translation is unsupported."
        }
    }

    private func refreshSpeechModels() async {
        let supported = await pipeline.supportedSpeechLanguages()
        let installed = Set(await pipeline.installedSpeechLanguages())
        var resources: [SpeechModelResource] = []
        resources.reserveCapacity(supported.count)

        for language in supported {
            guard !Task.isCancelled else { return }
            let status: SpeechResourceStatus
            if installed.contains(language) {
                status = .installed
            } else {
                status = await pipeline.speechResourceStatus(for: language)
            }
            resources.append(SpeechModelResource(language: language, status: status))
        }

        speechModels = resources
    }

    private func updateSpeechModel(_ language: Language, status: SpeechResourceStatus) {
        guard let index = speechModels.firstIndex(where: { $0.language == language }) else {
            return
        }
        speechModels[index].status = status
    }

    private func refreshInstalledLanguageSelections() async {
        let installed = await pipeline.installedSpeechLanguages()
        installedSpokenLanguages = installed

        guard !installed.isEmpty else {
            spokenLanguage = nil
            translatedToLanguage = nil
            installedTranslatedToLanguages = []
            modelStatusText = "No on-device Speech models are installed."
            resetConversationText()
            return
        }

        if let spokenLanguage, installed.contains(spokenLanguage) {
            // Keep the current spoken-language selection.
        } else {
            spokenLanguage = preferredLanguage(in: installed)
        }

        guard let spokenLanguage else { return }
        await reloadInstalledTranslatedToLanguages(
            for: spokenLanguage,
            preservingSelection: true
        )
        await updateInterfacePrompts()
        await refreshTranslationModelStatus()
    }

    private func resetConversationText() {
        spokenLanguageText = Self.spokenPrompt
        translatedToLanguageText = Self.translatedToPrompt
    }

    private func language(for role: LanguageRole) -> Language? {
        role == .translatedTo ? translatedToLanguage : spokenLanguage
    }

    private func setText(_ text: String, for role: LanguageRole) {
        if role == .translatedTo {
            translatedToLanguageText = text
        } else {
            spokenLanguageText = text
        }
    }

    private func reloadInstalledTranslatedToLanguages(
        for spoken: Language,
        preservingSelection: Bool
    ) async {
        let forwardTargets = await pipeline.installedTranslatedToLanguages(from: spoken)
        var translatedToLanguages: [Language] = []
        for translatedTo in forwardTargets where installedSpokenLanguages.contains(translatedTo) {
            guard !Task.isCancelled else { return }
            if await pipeline.translationResourceStatus(
                from: translatedTo,
                to: spoken
            ) == .installed {
                translatedToLanguages.append(translatedTo)
            }
        }
        guard !Task.isCancelled, spokenLanguage == spoken else { return }

        installedTranslatedToLanguages = translatedToLanguages
        if preservingSelection,
           let translatedToLanguage,
           translatedToLanguages.contains(translatedToLanguage) {
            return
        }

        let indonesian = language(matching: "id", in: translatedToLanguages)
        translatedToLanguage = indonesian ?? translatedToLanguages.first
        if translatedToLanguages.isEmpty {
            modelStatusText = "No offline Translation models are installed for \(spoken.displayName())."
        }
    }

    private func updateInterfacePrompts() async {
        await updateSpokenPrompt()
        await updateTranslatedToPrompt()
    }

    private func updateSpokenPrompt() async {
        guard let selectedLanguage = spokenLanguage else {
            spokenLanguageText = Self.spokenPrompt
            return
        }

        let selectedCode = Locale(identifier: selectedLanguage.identifier).language.languageCode
        let englishCode = Locale(identifier: Self.english.identifier).language.languageCode
        guard selectedCode != englishCode else {
            if state == .idle, spokenLanguage == selectedLanguage {
                spokenLanguageText = Self.spokenPrompt
            }
            return
        }

        let localizedPrompt = try? await pipeline.translateText(
            Self.spokenPrompt,
            from: Self.english,
            to: selectedLanguage
        )

        guard state == .idle, spokenLanguage == selectedLanguage else { return }
        spokenLanguageText = localizedPrompt ?? Self.spokenPrompt
    }

    private func updateTranslatedToPrompt() async {
        guard let selectedLanguage = translatedToLanguage else {
            translatedToLanguageText = Self.translatedToPrompt
            return
        }

        let selectedCode = Locale(identifier: selectedLanguage.identifier).language.languageCode
        let englishCode = Locale(identifier: Self.english.identifier).language.languageCode
        guard selectedCode != englishCode else {
            if state == .idle, translatedToLanguage == selectedLanguage {
                translatedToLanguageText = Self.translatedToPrompt
            }
            return
        }

        let localizedPrompt = try? await pipeline.translateText(
            Self.translatedToPrompt,
            from: Self.english,
            to: selectedLanguage
        )

        guard state == .idle, translatedToLanguage == selectedLanguage else { return }
        translatedToLanguageText = localizedPrompt ?? Self.translatedToPrompt
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

private extension TranscriptionViewModel.LanguageRole {
    var opposite: Self {
        self == .translatedTo ? .spoken : .translatedTo
    }
}
