nonisolated enum SpeechResourceStatus: Equatable, Sendable {
    case unsupported
    case downloadable
    case downloading
    case installed
}

nonisolated struct SpeechModelResource: Identifiable, Equatable, Sendable {
    let language: Language
    var status: SpeechResourceStatus

    var id: String { language.id }
}
