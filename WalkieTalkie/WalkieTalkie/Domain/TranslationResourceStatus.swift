import Foundation

nonisolated enum TranslationResourceStatus: Equatable, Sendable {
    case unsupported
    case downloadable
    case installed
}
