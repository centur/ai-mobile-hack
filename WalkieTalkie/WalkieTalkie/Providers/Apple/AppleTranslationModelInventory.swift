import Foundation
import Translation

/// Translation's equivalent of a model inventory.
///
/// `Speech.AssetInventory` cannot report translation assets. Translation exposes
/// installed model pairs through `LanguageAvailability` instead.
nonisolated struct AppleTranslationModelInventory: TranslationModelInventorying {
    nonisolated func resourceStatus(
        from source: Language,
        to target: Language
    ) async -> TranslationResourceStatus {
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        let status = await availability.status(
            from: Locale.Language(identifier: source.identifier),
            to: Locale.Language(identifier: target.identifier)
        )

        switch status {
        case .installed:
            return .installed
        case .supported:
            return .downloadable
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }
}
