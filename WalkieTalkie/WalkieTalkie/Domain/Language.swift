import Foundation

/// Framework-neutral language identifier used across provider boundaries.
nonisolated struct Language: Hashable, Identifiable, Sendable {
    let identifier: String

    var id: String { identifier }

    init(identifier: String) {
        self.identifier = Locale(identifier: identifier).identifier(.bcp47)
    }

    /// A region-independent language value suitable for model selection UI.
    /// Apple Speech exposes locale-specific assets (for example, en-US and
    /// en-AU), while Translation exposes languages. The app presents one row
    /// per underlying language and lets the provider choose an installed locale.
    var baseLanguage: Language {
        let language = Locale.Language(identifier: identifier)
        return Language(identifier: language.languageCode?.identifier ?? language.minimalIdentifier)
    }

    func displayName(in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }
}
