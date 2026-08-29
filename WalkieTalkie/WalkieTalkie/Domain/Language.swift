import Foundation

/// Framework-neutral language identifier used across provider boundaries.
nonisolated struct Language: Hashable, Identifiable, Sendable {
    let identifier: String

    var id: String { identifier }

    init(identifier: String) {
        self.identifier = Locale(identifier: identifier).identifier(.bcp47)
    }

    func displayName(in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }
}
