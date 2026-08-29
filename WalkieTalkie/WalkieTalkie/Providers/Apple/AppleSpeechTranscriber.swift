@preconcurrency import AVFAudio
import Foundation
import Speech

actor AppleSpeechTranscriber: SpeechTranscribing {
    private var analyzer: SpeechAnalyzer?
    private var analyzerInputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var sessionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    func supportedLanguages() async -> [Language] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales
            .map { Language(identifier: $0.identifier(.bcp47)) }
            .sorted { $0.identifier < $1.identifier }
    }

    func resourceStatus(for language: Language) async -> SpeechResourceStatus {
        guard SpeechTranscriber.isAvailable else { return .unsupported }
        guard let locale = await supportedLocale(for: language) else { return .unsupported }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported:
            return .unsupported
        case .supported:
            return .downloadable
        case .downloading:
            return .downloading
        case .installed:
            return .installed
        @unknown default:
            return .unsupported
        }
    }

    func prepare(language: Language) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechBackendError.speechTranscriberUnavailable
        }
        guard let locale = await supportedLocale(for: language) else {
            throw SpeechBackendError.unsupportedLanguage(language.identifier)
        }

        _ = try await AssetInventory.reserve(locale: locale)
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw SpeechBackendError.resourceNotInstalled(language.identifier)
        }
    }

    func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        language: Language
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        await cancel()

        guard SpeechTranscriber.isAvailable else {
            throw SpeechBackendError.speechTranscriberUnavailable
        }
        guard let locale = await supportedLocale(for: language) else {
            throw SpeechBackendError.unsupportedLanguage(language.identifier)
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw SpeechBackendError.resourceNotInstalled(language.identifier)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw SpeechBackendError.invalidAudioFormat
        }

        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (analyzerInputs, inputContinuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
        self.analyzer = analyzer
        analyzerInputContinuation = inputContinuation

        let (results, resultsContinuation) = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()

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

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    resultsContinuation.yield(
                        TranscriptSegment(
                            text: String(result.text.characters),
                            isFinal: result.isFinal,
                            alternatives: result.alternatives.map { String($0.characters) }
                        )
                    )
                }
                resultsContinuation.finish()
            } catch is CancellationError {
                resultsContinuation.finish()
            } catch {
                resultsContinuation.finish(throwing: error)
            }
        }

        resultsContinuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancel() }
        }

        return results
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

    private func supportedLocale(for language: Language) async -> Locale? {
        await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.identifier)
        )
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
