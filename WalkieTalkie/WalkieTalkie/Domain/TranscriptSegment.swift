import Foundation

nonisolated struct TranscriptSegment: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let alternatives: [String]
    let startTime: TimeInterval?
    let duration: TimeInterval?

    init(
        id: UUID = UUID(),
        text: String,
        isFinal: Bool,
        alternatives: [String] = [],
        startTime: TimeInterval? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.alternatives = alternatives
        self.startTime = startTime
        self.duration = duration
    }
}
