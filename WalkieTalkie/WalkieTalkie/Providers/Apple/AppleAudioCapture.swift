import AVFAudio

actor AppleAudioCapture: AudioCapturing {
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() async throws -> AsyncThrowingStream<AudioFrame, Error> {
        guard continuation == nil else {
            throw SpeechBackendError.captureAlreadyRunning
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            try? session.setActive(false)
            throw SpeechBackendError.invalidAudioFormat
        }

        let (stream, streamContinuation) = AsyncThrowingStream<AudioFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(200)
        )
        continuation = streamContinuation

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            guard let channels = buffer.floatChannelData else {
                streamContinuation.finish(throwing: SpeechBackendError.invalidAudioFormat)
                return
            }

            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            var monoSamples = [Float](repeating: 0, count: frameCount)

            for channelIndex in 0..<channelCount {
                let channel = channels[channelIndex]
                for frameIndex in 0..<frameCount {
                    monoSamples[frameIndex] += channel[frameIndex] / Float(channelCount)
                }
            }

            streamContinuation.yield(
                AudioFrame(samples: monoSamples, sampleRate: buffer.format.sampleRate)
            )
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            continuation = nil
            streamContinuation.finish(throwing: error)
            try? session.setActive(false)
            throw error
        }

        streamContinuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }

        return stream
    }

    func stop() async {
        guard let continuation else { return }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.continuation = nil
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
