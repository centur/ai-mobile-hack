import Foundation
@preconcurrency import Translation

/// Translation's equivalent of a model inventory.
///
/// `Speech.AssetInventory` cannot report translation assets. Translation exposes
/// installed model pairs through `LanguageAvailability` instead.
nonisolated struct AppleTranslationModelInventory: TranslationModelInventorying {
    nonisolated func installedTargetLanguages(from source: Language) async -> [Language] {
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        let sourceLanguage = Locale.Language(identifier: source.identifier)
        let supportedLanguages = await availability.supportedLanguages
        var installed: Set<Language> = []

        for targetLanguage in supportedLanguages {
            let target = Language(identifier: targetLanguage.minimalIdentifier).baseLanguage
            guard target != source.baseLanguage else { continue }

            if await availability.status(from: sourceLanguage, to: targetLanguage) == .installed {
                installed.insert(target)
            }
        }

        return installed.sorted {
            $0.displayName().localizedCaseInsensitiveCompare($1.displayName()) == .orderedAscending
        }
    }

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
