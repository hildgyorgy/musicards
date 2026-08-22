import Foundation

enum LibrarySource: String, Hashable, Sendable {
    case local
    case navidrome
}

nonisolated enum LibrarySourceSelectionPolicy {
    static func sourceAfterDisconnect(
        _ disconnectedSource: LibrarySource,
        activeSource: LibrarySource?,
        localIsConnected: Bool,
        navidromeIsConnected: Bool
    ) -> LibrarySource? {
        guard activeSource == disconnectedSource else { return activeSource }

        switch disconnectedSource {
        case .local:
            return navidromeIsConnected ? .navidrome : nil
        case .navidrome:
            return localIsConnected ? .local : nil
        }
    }
}

nonisolated enum LibrarySourcePreference {
    private static let key = "MusiCards.activeLibrarySource.v1"

    static func load(from defaults: UserDefaults = .standard) -> LibrarySource? {
        guard let rawValue = defaults.string(forKey: key) else { return nil }
        return LibrarySource(rawValue: rawValue)
    }

    static func restoredSource(
        from defaults: UserDefaults = .standard,
        navidromeIsConfigured: Bool
    ) -> LibrarySource {
        let savedSource = load(from: defaults)
        if savedSource == .navidrome, navidromeIsConfigured {
            return .navidrome
        }
        return .local
    }

    static func save(
        _ source: LibrarySource?,
        to defaults: UserDefaults = .standard
    ) {
        if let source {
            defaults.set(source.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
