import Foundation

nonisolated enum TranslationResourceStatus: Equatable, Sendable {
    case unsupported
    case downloadable
    case installed
}

nonisolated struct TranslationModelResource: Identifiable, Equatable, Sendable {
    let language: Language
    let status: TranslationResourceStatus

    var id: String { language.id }
}
