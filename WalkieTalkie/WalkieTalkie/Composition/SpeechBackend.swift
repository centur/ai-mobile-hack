enum SpeechBackend {
    static func makeAppleOnDevice() -> SpeechToTextConverter {
        SpeechToTextConverter(
            audioCapture: AppleAudioCapture(),
            transcriber: AppleSpeechTranscriber()
        )
    }
}
