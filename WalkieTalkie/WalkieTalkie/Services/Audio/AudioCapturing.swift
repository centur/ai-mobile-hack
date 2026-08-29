protocol AudioCapturing: Sendable {
    func requestPermission() async -> Bool
    func start() async throws -> AsyncThrowingStream<AudioFrame, Error>
    func stop() async
}
