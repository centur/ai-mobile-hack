enum SpeechBackend {
    static func makeAppleOnDevice() -> VoiceTranslationPipeline {
        VoiceTranslationPipeline(
            speechConverter: SpeechToTextConverter(
                audioCapture: AppleAudioCapture(),
                transcriber: AppleSpeechTranscriber()
            ),
            translator: AppleTextTranslator(),
            modelInventory: AppleTranslationModelInventory()
        )
    }
}
