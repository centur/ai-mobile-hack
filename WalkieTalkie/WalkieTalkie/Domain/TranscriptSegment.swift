import Foundation

nonisolated struct TranscriptSegment: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let alternatives: [String]

    init(
        id: UUID = UUID(),
        text: String,
        isFinal: Bool,
        alternatives: [String] = []
    ) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.alternatives = alternatives
    }
}
