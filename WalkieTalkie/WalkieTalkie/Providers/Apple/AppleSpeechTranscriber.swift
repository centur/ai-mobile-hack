@preconcurrency import AVFAudio
import Foundation
import Speech

actor AppleSpeechTranscriber: SpeechTranscribing {
    private enum Backend {
        case speech(Locale)
        case dictation(Locale)
    }

    private var analyzer: SpeechAnalyzer?
    private var analyzerInputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var sessionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    func supportedLanguages() async -> [Language] {
        var locales = await DictationTranscriber.supportedLocales
        if SpeechTranscriber.isAvailable {
            locales.append(contentsOf: await SpeechTranscriber.supportedLocales)
        }
        let languages = locales.compactMap(Self.baseLanguage)
        return Self.sortedUnique(languages)
    }

    func installedLanguages() async -> [Language] {
        let dictationInstalled = await DictationTranscriber.installedLocales
        guard SpeechTranscriber.isAvailable else {
            return Self.sortedUnique(dictationInstalled.compactMap(Self.baseLanguage))
        }

        let speechSupported = Set(
            await SpeechTranscriber.supportedLocales.compactMap(Self.baseLanguage)
        )
        var installed = await SpeechTranscriber.installedLocales.compactMap(Self.baseLanguage)
        installed.append(
            contentsOf: dictationInstalled.compactMap(Self.baseLanguage).filter {
                !speechSupported.contains($0)
            }
        )
        return Self.sortedUnique(installed)
    }

    func resourceStatus(for language: Language) async -> SpeechResourceStatus {
        guard let backend = await backend(for: language) else { return .unsupported }

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

    func prepare(language: Language) async throws {
        guard let backend = await backend(for: language) else {
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

        guard let backend = await backend(for: language) else {
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

    private func backend(for language: Language) async -> Backend? {
        let locale = Locale(identifier: language.identifier)
        if SpeechTranscriber.isAvailable,
           let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speech(speechLocale)
        }
        if let dictationLocale = await DictationTranscriber.supportedLocale(
            equivalentTo: locale
        ) {
            return .dictation(dictationLocale)
        }
        return nil
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
