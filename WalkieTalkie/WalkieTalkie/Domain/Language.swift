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

    /// A representative flag for this language's most likely region.
    var flagEmoji: String {
        let maximalIdentifier = Locale.Language(identifier: identifier).maximalIdentifier
        guard let region = Locale(identifier: maximalIdentifier).region?.identifier else {
            return "🌐"
        }

        let letters = Array(region.uppercased().unicodeScalars)
        guard letters.count == 2,
              letters.allSatisfy({ (65...90).contains($0.value) }) else {
            return "🌐"
        }

        let regionalIndicators = letters.compactMap {
            UnicodeScalar(127_397 + $0.value)
        }
        return String(String.UnicodeScalarView(regionalIndicators))
    }
}
