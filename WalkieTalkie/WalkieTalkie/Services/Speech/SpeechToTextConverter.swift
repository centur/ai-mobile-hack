/// Coordinates microphone capture and a replaceable speech recognition provider.
actor SpeechToTextConverter {
    private let audioCapture: any AudioCapturing
    private let transcriber: any SpeechTranscribing
    private var isRunning = false
    private var relayTask: Task<Void, Never>?

    init(
        audioCapture: any AudioCapturing,
        transcriber: any SpeechTranscribing
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
    }

    func supportedLanguages() async -> [Language] {
        await transcriber.supportedLanguages()
    }

    func installedLanguages() async -> [Language] {
        await transcriber.installedLanguages()
    }

    func resourceStatus(for language: Language) async -> SpeechResourceStatus {
        await transcriber.resourceStatus(for: language)
    }

    func prepare(language: Language) async throws {
        try await transcriber.prepare(language: language)
    }

    func start(language: Language) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        guard !isRunning else {
            throw SpeechBackendError.captureAlreadyRunning
        }

        guard await audioCapture.requestPermission() else {
            throw SpeechBackendError.microphonePermissionDenied
        }

        let audio = try await audioCapture.start()

        do {
            let providerResults = try await transcriber.transcribe(audio, language: language)
            let (results, continuation) = AsyncThrowingStream<TranscriptSegment, Error>.makeStream(
                bufferingPolicy: .bufferingNewest(50)
            )
            isRunning = true

            relayTask = Task {
                do {
                    for try await segment in providerResults {
                        try Task.checkCancellation()
                        continuation.yield(segment)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await sessionDidEnd()
            }

            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { await self?.cancel() }
            }

            return results
        } catch {
            await audioCapture.stop()
            throw error
        }
    }

    /// Finalizes buffered audio so the result stream can emit its last segment.
    func finish() async {
        guard isRunning else { return }
        await audioCapture.stop()
        await transcriber.finish()
        isRunning = false
    }

    /// Immediately abandons the current capture and recognition session.
    func cancel() async {
        relayTask?.cancel()
        relayTask = nil
        await audioCapture.stop()
        await transcriber.cancel()
        isRunning = false
    }

    private func sessionDidEnd() async {
        await audioCapture.stop()
        relayTask = nil
        isRunning = false
    }
}
