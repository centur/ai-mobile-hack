import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionViewModel {
    private static let spokenPrompt = "Tap a microphone and start speaking."
    private static let translatedToPrompt = "Translation will appear here."
    private static let english = Language(identifier: "en")
    private static let silenceDurationKey = "translationSilenceDurationSeconds"
    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？", "؟", "।", "॥"
    ]
    private static let trailingClausePunctuation: Set<Character> = [",", ";", ":"]

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
    private var suppressedCaptureID: UUID?
    private var languageSelectionTask: Task<Void, Never>?
    private var hasLoadedLanguages = false

    private(set) var state: State = .idle
    private(set) var installedSpokenLanguages: [Language] = []
    private(set) var installedTranslatedToLanguages: [Language] = []
    private(set) var speechModels: [SpeechModelResource] = []
    private(set) var translationModels: [TranslationModelResource] = []
    private(set) var isLoadingLanguages = false
    private(set) var isLoadingSpeechModels = false
    private(set) var isLoadingTranslationModels = false
    private(set) var speechModelOperationLanguage: Language?
    private(set) var translationModelOperationLanguage: Language?
    private(set) var pendingTranslationDownload: TranslationDownloadRequest?
    private(set) var selectedPairReadiness: OfflineLanguagePairReadiness?
    private(set) var speechModelManagerMessage: String?
    private(set) var translationModelManagerMessage: String?
    private(set) var spokenLanguageText = spokenPrompt
    private(set) var translatedToLanguageText = translatedToPrompt
    private(set) var modelStatusText = "Loading installed languages…"
    private(set) var activeMicrophoneRole: LanguageRole?
    private(set) var silenceDurationSeconds = 1.0

    var translatedToLanguage: Language?
    var spokenLanguage: Language?

    init(pipeline: VoiceTranslationPipeline = SpeechBackend.makeAppleOnDevice()) {
        self.pipeline = pipeline
        if let savedDuration = UserDefaults.standard.object(
            forKey: Self.silenceDurationKey
        ) as? Double {
            silenceDurationSeconds = min(max(savedDuration, 0.5), 5.0)
        }
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

    func loadTranslationModels() async {
        guard translationModelOperationLanguage == nil else { return }
        isLoadingTranslationModels = true
        translationModelManagerMessage = nil
        await refreshTranslationModels()
        isLoadingTranslationModels = false
    }

    func prepareOfflinePair(with language: Language) async {
        guard state == .idle, translationModelOperationLanguage == nil else { return }
        guard let model = translationModels.first(where: { $0.language == language }) else {
            return
        }
        guard model.readiness.isBidirectionallySupported else {
            translationModelManagerMessage = "Two-way offline use with \(language.displayName()) is not supported on this device."
            return
        }

        translationModelOperationLanguage = language
        translationModelManagerMessage = nil

        do {
            if model.readiness.firstSpeech != .installed {
                try await pipeline.prepareSpeech(language: model.readiness.firstLanguage)
            }
            if model.readiness.secondSpeech != .installed {
                try await pipeline.prepareSpeech(language: model.readiness.secondLanguage)
            }
            await continueOfflinePairPreparation(with: language)
        } catch {
            await failOfflinePairPreparation(error: error)
        }
    }

    func finishTranslationModelDownload(_ request: TranslationDownloadRequest) async {
        guard pendingTranslationDownload == request,
              let language = translationModelOperationLanguage,
              let spokenLanguage else { return }
        pendingTranslationDownload = nil

        // The system download sheet can finish just before LanguageAvailability
        // publishes its new state. Wait briefly instead of launching the same
        // download again or claiming readiness prematurely.
        var requestIsInstalled = false
        for attempt in 0..<5 {
            let readiness = await pipeline.offlineReadiness(
                between: spokenLanguage,
                and: language
            )
            if readiness.translationStatus(
                from: request.source,
                to: request.target
            ) == .installed {
                requestIsInstalled = true
                break
            }
            if attempt < 4 {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        guard requestIsInstalled else {
            translationModelManagerMessage = "The system download finished, but iOS has not reported the Translation model as installed. Pull to refresh and try again."
            await refreshTranslationModels()
            translationModelOperationLanguage = nil
            await refreshTranslationModelStatus()
            return
        }
        await continueOfflinePairPreparation(with: language)
    }

    func failTranslationModelDownload(
        _ request: TranslationDownloadRequest,
        error: Error
    ) async {
        guard pendingTranslationDownload == request else { return }
        await failOfflinePairPreparation(error: error)
    }

    func showTranslationModelRemovalInstructions(for language: Language) {
        translationModelManagerMessage = "Apple manages Translation models. To delete the \(language.displayName()) model, open Settings, go to Apps → Translate → Downloaded Languages, then remove it there."
    }

    func clearTranslationModelManagerMessage() {
        translationModelManagerMessage = nil
    }

    func setSilenceDuration(seconds: Double) {
        guard state == .idle else { return }
        silenceDurationSeconds = min(max(seconds, 0.5), 5.0)
        UserDefaults.standard.set(
            silenceDurationSeconds,
            forKey: Self.silenceDurationKey
        )
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
            if activeMicrophoneRole == .spoken {
                clearPanelsForStoppedSourceCapture()
            }
            if activeMicrophoneRole == role {
                cancelCapture()
            } else {
                switchCapture(to: role, finalizingCurrentCapture: false)
            }
        case .listening:
            if activeMicrophoneRole == .spoken {
                clearPanelsForStoppedSourceCapture()
            }
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
        suppressedCaptureID = nil
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
        guard let selectedLanguage = language(for: role),
              installedSpokenLanguages.contains(selectedLanguage) else { return false }
        guard let otherLanguage = language(for: role.opposite),
              selectedPairReadiness?.translationStatus(
                from: selectedLanguage,
                to: otherLanguage
              ) == .installed else { return false }
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
                if let captureTranslatedToLanguage {
                    let translationStatus = await pipeline.translationResourceStatus(
                       from: captureSpokenLanguage,
                       to: captureTranslatedToLanguage
                    )
                    switch translationStatus {
                    case .installed:
                        translationLanguage = captureTranslatedToLanguage
                    case .downloadable:
                        throw TranslationBackendError.modelNotInstalled(
                            spokenLanguage: captureSpokenLanguage.displayName(),
                            translatedToLanguage: captureTranslatedToLanguage.displayName()
                        )
                    case .unsupported:
                        throw TranslationBackendError.unsupportedPair(
                            spokenLanguage: captureSpokenLanguage.displayName(),
                            translatedToLanguage: captureTranslatedToLanguage.displayName()
                        )
                    }
                }

                try Task.checkCancellation()
                let results = try await pipeline.start(
                    spokenLanguage: captureSpokenLanguage,
                    translatedToLanguage: translationLanguage,
                    silenceDuration: .milliseconds(Int(silenceDurationSeconds * 1_000))
                )
                guard self.captureID == captureID else { return }
                state = .listening

                for try await result in results {
                    try Task.checkCancellation()
                    guard self.captureID == captureID else { return }
                    guard suppressedCaptureID != captureID else { continue }
                    setText(result.spokenLanguageText, for: role)
                    if let translation = result.translatedToLanguageText {
                        setText(translation, for: role.opposite)
                    }
                }

                guard self.captureID == captureID else { return }
                state = .idle
                activeMicrophoneRole = nil
                if suppressedCaptureID == captureID {
                    suppressedCaptureID = nil
                }
                self.captureID = nil
                transcriptionTask = nil
            } catch is CancellationError {
                guard self.captureID == captureID else { return }
                state = .idle
                activeMicrophoneRole = nil
                if suppressedCaptureID == captureID {
                    suppressedCaptureID = nil
                }
                self.captureID = nil
                transcriptionTask = nil
            } catch {
                guard self.captureID == captureID else { return }
                if suppressedCaptureID != captureID {
                    setText(error.localizedDescription, for: role)
                } else {
                    suppressedCaptureID = nil
                }
                modelStatusText = error.localizedDescription
                state = .idle
                activeMicrophoneRole = nil
                self.captureID = nil
                transcriptionTask = nil
                await pipeline.cancel()
                await refreshTranslationModelStatus()
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

            suppressedCaptureID = nil
            state = .idle
            captureTransitionTask = nil
            startCapture(for: role)
        }
    }

    private func refreshTranslationModelStatus() async {
        guard let translatedToLanguage, let spokenLanguage else {
            selectedPairReadiness = nil
            modelStatusText = installedSpokenLanguages.isEmpty
                ? "Install a Speech language in Settings."
                : "Select an installed offline language pair."
            return
        }
        guard translatedToLanguage != spokenLanguage else {
            selectedPairReadiness = nil
            modelStatusText = "Spoken and translated-to languages must be different."
            return
        }

        let readiness = await pipeline.offlineReadiness(
            between: spokenLanguage,
            and: translatedToLanguage
        )
        guard self.spokenLanguage == spokenLanguage,
              self.translatedToLanguage == translatedToLanguage else { return }
        selectedPairReadiness = readiness

        if readiness.isFullyReady {
            modelStatusText = "\(spokenLanguage.displayName()) ↔︎ \(translatedToLanguage.displayName()) is ready offline."
        } else if !readiness.isBidirectionallySupported {
            modelStatusText = "Two-way offline use is unsupported for this language pair."
        } else {
            modelStatusText = "Download the remaining resources for two-way offline use."
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

    private func refreshTranslationModels() async {
        guard let spokenLanguage else {
            translationModels = []
            return
        }

        let supported = await pipeline.supportedTranslatedToLanguages(from: spokenLanguage)
        var resources: [TranslationModelResource] = []
        resources.reserveCapacity(supported.count)

        for language in supported {
            guard !Task.isCancelled else { return }
            let readiness = await pipeline.offlineReadiness(
                between: spokenLanguage,
                and: language
            )
            resources.append(
                TranslationModelResource(language: language, readiness: readiness)
            )
        }

        translationModels = resources
    }

    private func continueOfflinePairPreparation(with language: Language) async {
        guard translationModelOperationLanguage == language,
              let spokenLanguage else { return }

        let readiness = await pipeline.offlineReadiness(
            between: spokenLanguage,
            and: language
        )
        updateTranslationModel(language, readiness: readiness)

        if readiness.firstToSecondTranslation == .downloadable {
            pendingTranslationDownload = TranslationDownloadRequest(
                source: readiness.firstLanguage,
                target: readiness.secondLanguage
            )
            return
        }
        if readiness.secondToFirstTranslation == .downloadable {
            pendingTranslationDownload = TranslationDownloadRequest(
                source: readiness.secondLanguage,
                target: readiness.firstLanguage
            )
            return
        }
        guard readiness.isFullyReady else {
            translationModelManagerMessage = "The language pair could not be made fully ready for offline use."
            translationModelOperationLanguage = nil
            await refreshTranslationModelStatus()
            return
        }

        await refreshInstalledLanguageSelections()
        await refreshTranslationModels()
        translationModelOperationLanguage = nil
        await refreshTranslationModelStatus()
    }

    private func failOfflinePairPreparation(error: Error) async {
        pendingTranslationDownload = nil
        translationModelManagerMessage = error.localizedDescription
        await refreshTranslationModels()
        translationModelOperationLanguage = nil
        await refreshTranslationModelStatus()
    }

    private func updateTranslationModel(
        _ language: Language,
        readiness: OfflineLanguagePairReadiness
    ) {
        guard let index = translationModels.firstIndex(where: {
            $0.language == language
        }) else { return }
        translationModels[index] = TranslationModelResource(
            language: language,
            readiness: readiness
        )
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
        selectedPairReadiness = nil
        spokenLanguageText = Self.spokenPrompt
        translatedToLanguageText = Self.translatedToPrompt
    }

    private func clearPanelsForStoppedSourceCapture() {
        suppressedCaptureID = captureID
        spokenLanguageText = ""
        translatedToLanguageText = ""
    }

    private func language(for role: LanguageRole) -> Language? {
        role == .translatedTo ? translatedToLanguage : spokenLanguage
    }

    private func setText(_ text: String, for role: LanguageRole) {
        let renderedText = punctuatedForDisplay(text)
        if role == .translatedTo {
            translatedToLanguageText = renderedText
        } else {
            spokenLanguageText = renderedText
        }
    }

    private func punctuatedForDisplay(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine in
                var line = String(rawLine)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let lastCharacter = line.last else { return "" }
                if Self.sentenceTerminators.contains(lastCharacter) {
                    return line
                }
                if Self.trailingClausePunctuation.contains(lastCharacter) {
                    line.removeLast()
                }
                return line + "."
            }
            .joined(separator: "\n")
    }

    private func reloadInstalledTranslatedToLanguages(
        for spoken: Language,
        preservingSelection: Bool
    ) async {
        let translatedToLanguages = await pipeline.installedTranslatedToLanguages(from: spoken)
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
