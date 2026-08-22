import Combine
import Foundation

/// Source-independent availability facade used by Search and library-aware UI.
///
@MainActor
final class LibraryManager: ObservableObject {
    private let localProvider: any LibraryProvider
    private let navidromeProvider: (any LibraryProvider)?
    private var provider: any LibraryProvider
    private var availabilityObservation: AnyCancellable?

    init(provider: any LibraryProvider) {
        self.localProvider = provider
        self.navidromeProvider = nil
        self.provider = provider
        observeActiveProvider()
    }

    init(
        localProvider: any LibraryProvider,
        navidromeProvider: any LibraryProvider
    ) {
        self.localProvider = localProvider
        self.navidromeProvider = navidromeProvider
        self.provider = localProvider
        observeActiveProvider()
    }

    private func observeActiveProvider() {
        availabilityObservation = provider.availabilityChanges.sink {
            @MainActor [weak self] in
            self?.objectWillChange.send()
        }
    }

    convenience init(localLibrary: LocalLibraryStore) {
        self.init(provider: LocalLibraryProvider(store: localLibrary))
    }

    var source: LibrarySource {
        provider.source
    }

    var catalogState: LibraryCatalogState {
        provider.catalogState
    }

    var catalogSummary: LibraryCatalogSummary {
        provider.catalogSummary
    }

    func setActiveSource(_ source: LibrarySource?) {
        let selectedProvider: any LibraryProvider
        switch source ?? .local {
        case .local:
            selectedProvider = localProvider
        case .navidrome:
            guard let navidromeProvider else { return }
            selectedProvider = navidromeProvider
        }

        guard provider !== selectedProvider else {
            if provider.source == .navidrome {
                switch provider.catalogState {
                case .unknown, .failed:
                    let providerToRefresh = provider
                    Task { await providerToRefresh.refreshCatalog() }
                case .loading, .ready:
                    break
                }
            }
            return
        }

        objectWillChange.send()
        provider = selectedProvider
        observeActiveProvider()

        if provider.source == .navidrome {
            let providerToRefresh = provider
            Task { await providerToRefresh.refreshCatalog() }
        }
    }

    func refreshActiveCatalog() async {
        await provider.refreshCatalog()
    }

    func refreshActiveCatalogIfNeeded() async {
        await provider.refreshCatalogIfNeeded()
    }

    func searchCatalog(
        query: String,
        limit: Int = 50
    ) -> [LibraryCatalogRelease] {
        provider.searchCatalog(query: query, limit: limit)
    }

    func prepareTrackAvailability(forRelease releaseID: String) async {
        await provider.prepareTrackAvailability(forRelease: releaseID)
    }

    func prepareTrackAvailability(
        forRelease releaseID: String,
        from source: LibrarySource
    ) async {
        switch source {
        case .local:
            await localProvider.prepareTrackAvailability(
                forRelease: releaseID
            )
        case .navidrome:
            await navidromeProvider?.prepareTrackAvailability(
                forRelease: releaseID
            )
        }
    }

    func containsRelease(_ releaseID: String) -> Bool {
        provider.containsRelease(releaseID)
    }

    func containsArtist(named artistName: String) -> Bool {
        provider.containsArtist(named: artistName)
    }

    func containsReleaseGroup(title: String, artistName: String) -> Bool {
        provider.containsReleaseGroup(title: title, artistName: artistName)
    }

    func containsTrack(_ identity: LibraryTrackIdentity) -> Bool {
        provider.containsTrack(identity)
    }

    func playableTrack(
        for identity: LibraryTrackIdentity
    ) -> LibraryPlayableTrack? {
        provider.playableTrack(for: identity)
    }

    func playableTrack(
        for identity: LibraryTrackIdentity,
        from source: LibrarySource
    ) -> LibraryPlayableTrack? {
        switch source {
        case .local:
            localProvider.playableTrack(for: identity)
        case .navidrome:
            navidromeProvider?.playableTrack(for: identity)
        }
    }
}

extension LibraryManager: PlaybackAssetResolving {
    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource {
        let resolvingProvider: any LibraryProvider
        switch reference.source {
        case .local:
            resolvingProvider = localProvider
        case .navidrome:
            guard let navidromeProvider else {
                throw PlaybackAssetResolutionError.providerUnavailable(
                    .navidrome
                )
            }
            resolvingProvider = navidromeProvider
        }
        return try await resolvingProvider.resolvePlaybackAsset(reference)
    }
}
