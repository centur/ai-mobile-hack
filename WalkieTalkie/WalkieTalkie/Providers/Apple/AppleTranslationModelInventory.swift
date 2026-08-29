import Foundation
@preconcurrency import Translation

/// Translation's equivalent of a model inventory.
///
/// `Speech.AssetInventory` cannot report translation assets. Translation exposes
/// installed model pairs through `LanguageAvailability` instead.
nonisolated struct AppleTranslationModelInventory: TranslationModelInventorying {
    nonisolated func installedTranslatedToLanguages(
        from spokenLanguage: Language
    ) async -> [Language] {
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        let spokenLocaleLanguage = Locale.Language(identifier: spokenLanguage.identifier)
        let supportedLanguages = await availability.supportedLanguages
        var installed: Set<Language> = []

        for translatedToLocaleLanguage in supportedLanguages {
            let translatedToLanguage = Language(
                identifier: translatedToLocaleLanguage.minimalIdentifier
            ).baseLanguage
            guard translatedToLanguage != spokenLanguage.baseLanguage else { continue }

            if await availability.status(
                from: spokenLocaleLanguage,
                to: translatedToLocaleLanguage
            ) == .installed {
                installed.insert(translatedToLanguage)
            }
        }

        return installed.sorted {
            $0.displayName().localizedCaseInsensitiveCompare($1.displayName()) == .orderedAscending
        }
    }

    nonisolated func resourceStatus(
        from spokenLanguage: Language,
        to translatedToLanguage: Language
    ) async -> TranslationResourceStatus {
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        let status = await availability.status(
            from: Locale.Language(identifier: spokenLanguage.identifier),
            to: Locale.Language(identifier: translatedToLanguage.identifier)
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
