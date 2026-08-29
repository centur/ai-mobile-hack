import Foundation

// Our custom protocol implementation for swappable models of Speech to text
protocol SpeechTranscribing: Sendable {
    func supportedLanguages() async -> [Language]
    func installedLanguages() async -> [Language]
    func resourceStatus(for language: Language) async -> SpeechResourceStatus
    func prepare(language: Language) async throws
    func remove(language: Language) async throws
    func transcribe(
        _ audio: AsyncThrowingStream<AudioFrame, Error>,
        language: Language
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error>
    func finish() async
    func cancel() async
}

nonisolated enum SpeechBackendError: LocalizedError, Sendable {
    case microphonePermissionDenied
    case captureAlreadyRunning
    case invalidAudioFormat
    case speechTranscriberUnavailable
    case unsupportedLanguage(String)
    case resourceNotInstalled(String)
    case resourceNotReserved(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is required to transcribe speech."
        case .captureAlreadyRunning:
            "Audio capture is already running."
        case .invalidAudioFormat:
            "The microphone provided an unsupported audio format."
        case .speechTranscriberUnavailable:
            "On-device speech transcription is unavailable on this device."
        case .unsupportedLanguage(let identifier):
            "Speech transcription does not support \(identifier)."
        case .resourceNotInstalled(let identifier):
            "The speech model for \(identifier) is not installed."
        case .resourceNotReserved(let identifier):
            "The speech model for \(identifier) is managed by the system or another app and cannot be removed here."
        }
    }
}
