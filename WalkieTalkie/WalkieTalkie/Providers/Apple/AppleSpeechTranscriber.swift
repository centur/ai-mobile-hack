@preconcurrency import AVFAudio
import Foundation
import OSLog
import Speech

actor AppleSpeechTranscriber: SpeechTranscribing {
    nonisolated private static let logger = Logger(
        subsystem: "SharpOps.WalkieTalkie",
        category: "SpeechModelInventory"
    )

    private enum Backend {
        case speech(Locale)
        case dictation(Locale)
    }

    private var analyzer: SpeechAnalyzer?
    private var analyzerInputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var sessionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    func supportedLanguages() async -> [Language] {
        let dictationLocales = await DictationTranscriber.supportedLocales
        let speechLocales = SpeechTranscriber.isAvailable
            ? await SpeechTranscriber.supportedLocales
            : []
        var locales = dictationLocales
        if SpeechTranscriber.isAvailable {
            locales.append(contentsOf: speechLocales)
        }
        let languages = locales.compactMap(Self.baseLanguage)
        let supported = Self.sortedUnique(languages)

        Self.logger.debug(
            "SpeechTranscriber locales: \(Self.identifiers(speechLocales), privacy: .public)"
        )
        Self.logger.debug(
            "DictationTranscriber locales: \(Self.identifiers(dictationLocales), privacy: .public)"
        )
        Self.logger.debug(
            "Merged model languages: \(supported.map { $0.identifier }.joined(separator: ", "), privacy: .public)"
        )
        return supported
    }

    func installedLanguages() async -> [Language] {
        var installed = await DictationTranscriber.installedLocales.compactMap(Self.baseLanguage)
        if SpeechTranscriber.isAvailable {
            installed.append(
                contentsOf: await SpeechTranscriber.installedLocales.compactMap(Self.baseLanguage)
            )
        }
        return Self.sortedUnique(installed)
    }

    func resourceStatus(for language: Language) async -> SpeechResourceStatus {
        let candidates = await backends(for: language)
        guard !candidates.isEmpty else { return .unsupported }

        var statuses: [SpeechResourceStatus] = []
        for candidate in candidates {
            statuses.append(await status(for: candidate, language: language))
        }

        if statuses.contains(.installed) { return .installed }
        if statuses.contains(.downloading) { return .downloading }
        if statuses.contains(.downloadable) { return .downloadable }
        return .unsupported
    }

    func prepare(language: Language) async throws {
        guard let backend = await preferredBackend(for: language) else {
            throw SpeechBackendError.unsupportedLanguage(language.identifier)
        }

        if await resourceStatus(for: language) == .installed {
            return
        }

        switch backend {
        case .speech(let locale):
            try await install(
                SpeechTranscriber(locale: locale, preset: .progressiveTranscription),
                locale: locale,
                language: language
            )
        case .dictation(let locale):
            try await install(
                DictationTranscriber(locale: locale, preset: .progressiveLongDictation),
                locale: locale,
                language: language
            )
        }
    }

    func remove(language: Language) async throws {
        let reservedLocales = await AssetInventory.reservedLocales
        let matchingLocales = reservedLocales.filter { Self.matches($0, language: language) }
        guard !matchingLocales.isEmpty else {
            throw SpeechBackendError.resourceNotReserved(language.displayName())
        }

        var released = false
        for locale in matchingLocales {
            released = await AssetInventory.release(reservedLocale: locale) || released
        }
        guard released else {
            throw SpeechBackendError.resourceNotReserved(language.displayName())
        }
    }

    func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        language: Language
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        await cancel()

        guard let backend = await preferredBackend(for: language) else {
            throw SpeechBackendError.unsupportedLanguage(language.identifier)
        }

        let (results, resultsContinuation) = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()

        switch backend {
        case .speech(let locale):
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            try await startAnalysis(
                audio,
                module: transcriber,
                language: language,
                resultsContinuation: resultsContinuation
            )
            resultsTask = Task {
                await Self.consume(
                    transcriber.results,
                    continuation: resultsContinuation
                )
            }
        case .dictation(let locale):
            let transcriber = DictationTranscriber(
                locale: locale,
                preset: .progressiveLongDictation
            )
            try await startAnalysis(
                audio,
                module: transcriber,
                language: language,
                resultsContinuation: resultsContinuation
            )
            resultsTask = Task {
                await Self.consume(
                    transcriber.results,
                    continuation: resultsContinuation
                )
            }
        }

        resultsContinuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancel() }
        }

        return results
    }

    private func startAnalysis(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        module: any SpeechModule,
        language: Language,
        resultsContinuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) async throws {
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw SpeechBackendError.resourceNotInstalled(language.identifier)
        }

        let modules: [any SpeechModule] = [module]
        let analyzer = SpeechAnalyzer(modules: modules)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw SpeechBackendError.invalidAudioFormat
        }

        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (analyzerInputs, inputContinuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
        self.analyzer = analyzer
        analyzerInputContinuation = inputContinuation

        sessionTask = Task {
            do {
                async let analysis: Void = analyzer.start(inputSequence: analyzerInputs)

                for try await frame in audio {
                    try Task.checkCancellation()
                    let buffer = try Self.makeBuffer(from: frame, targetFormat: analyzerFormat)
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                }

                inputContinuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try await analysis
            } catch is CancellationError {
                inputContinuation.finish()
                await analyzer.cancelAndFinishNow()
            } catch {
                inputContinuation.finish(throwing: error)
                await analyzer.cancelAndFinishNow()
                resultsContinuation.finish(throwing: error)
            }
        }
    }

    private nonisolated static func consume<Results: AsyncSequence & Sendable>(
        _ results: Results,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) async where Results.Element: SpeechModuleResult & Sendable, Results.Failure == any Error {
        do {
            for try await result in results {
                if let speechResult = result as? SpeechTranscriber.Result {
                    continuation.yield(Self.segment(from: speechResult))
                } else if let dictationResult = result as? DictationTranscriber.Result {
                    continuation.yield(Self.segment(from: dictationResult))
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    func finish() async {
        // Audio capture closes its stream first. Let the feeder drain every queued
        // frame before it closes and finalizes the analyzer input.
        await sessionTask?.value
        await resultsTask?.value
        sessionTask = nil
        resultsTask = nil
        analyzerInputContinuation = nil
        analyzer = nil
    }

    func cancel() async {
        sessionTask?.cancel()
        resultsTask?.cancel()
        sessionTask = nil
        resultsTask = nil
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }

    private func backends(for language: Language) async -> [Backend] {
        let locale = Locale(identifier: language.identifier)
        var candidates: [Backend] = []
        if SpeechTranscriber.isAvailable,
           let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            candidates.append(.speech(speechLocale))
        }
        if let dictationLocale = await DictationTranscriber.supportedLocale(
            equivalentTo: locale
        ) {
            candidates.append(.dictation(dictationLocale))
        }
        return candidates
    }

    /// Prefer an installed backend, then one that is downloading or downloadable.
    /// Speech wins ties, while Dictation remains a real fallback when Speech merely
    /// advertises a locale whose requested asset preset is unsupported.
    private func preferredBackend(for language: Language) async -> Backend? {
        let candidates = await backends(for: language)
        var downloading: Backend?
        var downloadable: Backend?
        var unsupported: Backend?

        for candidate in candidates {
            switch await status(for: candidate, language: language) {
            case .installed:
                return candidate
            case .downloading:
                downloading = downloading ?? candidate
            case .downloadable:
                downloadable = downloadable ?? candidate
            case .unsupported:
                unsupported = unsupported ?? candidate
            }
        }

        return downloading ?? downloadable ?? unsupported
    }

    private func status(
        for backend: Backend,
        language: Language
    ) async -> SpeechResourceStatus {
        switch backend {
        case .speech(let locale):
            for installedLocale in await SpeechTranscriber.installedLocales
            where Self.matches(installedLocale, language: language) {
                let module = SpeechTranscriber(
                    locale: installedLocale,
                    preset: .progressiveTranscription
                )
                if await AssetInventory.status(forModules: [module]) == .installed {
                    return .installed
                }
            }
            return await Self.resourceStatus(
                for: SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            )
        case .dictation(let locale):
            for installedLocale in await DictationTranscriber.installedLocales
            where Self.matches(installedLocale, language: language) {
                let module = DictationTranscriber(
                    locale: installedLocale,
                    preset: .progressiveLongDictation
                )
                if await AssetInventory.status(forModules: [module]) == .installed {
                    return .installed
                }
            }
            return await Self.resourceStatus(
                for: DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            )
        }
    }

    private func install(
        _ module: any SpeechModule,
        locale: Locale,
        language: Language
    ) async throws {
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module]
        ) {
            try await request.downloadAndInstall()
        }

        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw SpeechBackendError.resourceNotInstalled(language.identifier)
        }
    }

    private nonisolated static func resourceStatus(
        for module: any SpeechModule
    ) async -> SpeechResourceStatus {
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported:
            .unsupported
        case .supported:
            .downloadable
        case .downloading:
            .downloading
        case .installed:
            .installed
        @unknown default:
            .unsupported
        }
    }

    private nonisolated static func segment(
        from result: SpeechTranscriber.Result
    ) -> TranscriptSegment {
        TranscriptSegment(
            text: String(result.text.characters),
            isFinal: result.isFinal,
            alternatives: result.alternatives.map { String($0.characters) }
        )
    }

    private nonisolated static func segment(
        from result: DictationTranscriber.Result
    ) -> TranscriptSegment {
        TranscriptSegment(
            text: String(result.text.characters),
            isFinal: result.isFinal,
            alternatives: result.alternatives.map { String($0.characters) }
        )
    }

    private nonisolated static func baseLanguage(for locale: Locale) -> Language? {
        let identifier = locale.identifier(.bcp47)
        guard !identifier.isEmpty,
              identifier.caseInsensitiveCompare("und") != .orderedSame else {
            return nil
        }
        return Language(identifier: identifier).baseLanguage
    }

    private nonisolated static func matches(_ locale: Locale, language: Language) -> Bool {
        baseLanguage(for: locale) == language.baseLanguage
    }

    private nonisolated static func sortedUnique(_ languages: [Language]) -> [Language] {
        Array(Set(languages)).sorted {
            $0.displayName().localizedCaseInsensitiveCompare($1.displayName()) == .orderedAscending
        }
    }

    private nonisolated static func identifiers(_ locales: [Locale]) -> String {
        locales.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
    }

    private nonisolated static func makeBuffer(
        from frame: AudioFrame,
        targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard !frame.samples.isEmpty,
              let sourceFormat = AVAudioFormat(
                  standardFormatWithSampleRate: frame.sampleRate,
                  channels: 1
              ),
              let sourceBuffer = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat,
                  frameCapacity: AVAudioFrameCount(frame.samples.count)
              ),
              let sourceChannel = sourceBuffer.floatChannelData?[0] else {
            throw SpeechBackendError.invalidAudioFormat
        }

        sourceBuffer.frameLength = AVAudioFrameCount(frame.samples.count)
        sourceChannel.update(from: frame.samples, count: frame.samples.count)

        if sourceFormat == targetFormat {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SpeechBackendError.invalidAudioFormat
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * ratio) + 1)
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            throw SpeechBackendError.invalidAudioFormat
        }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
            guard inputState.takeInput() else {
                outputStatus.pointee = .noDataNow
                return nil
            }
            outputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, conversionError == nil else {
            throw conversionError ?? SpeechBackendError.invalidAudioFormat
        }
        return converted
    }
}

private nonisolated final class ConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable = true

    func takeInput() -> Bool {
        lock.withLock {
            guard isAvailable else { return false }
            isAvailable = false
            return true
        }
    }
}
