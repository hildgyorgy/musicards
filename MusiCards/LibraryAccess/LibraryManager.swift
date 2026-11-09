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
    private let metadataService: any MusicBrainzSearchServing
    private var releaseMetadata: [String: MBReleaseSearchResult] = [:]
    private var releasesByGroup: [String: Set<String>] = [:]

    init(
        provider: any LibraryProvider,
        metadataService: any MusicBrainzSearchServing = MusicBrainzService()
    ) {
        self.metadataService = metadataService
        self.localProvider = provider
        self.navidromeProvider = nil
        self.provider = provider
        observeActiveProvider()
    }

    init(
        localProvider: any LibraryProvider,
        navidromeProvider: any LibraryProvider,
        metadataService: any MusicBrainzSearchServing = MusicBrainzService()
    ) {
        self.metadataService = metadataService
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
        query: LibraryCatalogQuery,
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

    /// Membership is MusicBrainz metadata; ownership is always checked against
    /// the current provider, including after disconnects and source changes.
    func containsReleaseGroup(id: String) -> Bool {
        releasesByGroup[id.lowercased()]?.contains {
            provider.containsRelease($0)
        } == true
    }

    func rememberReleaseGroup(id: String, releaseIDs: [String]) {
        let key = id.lowercased()
        let previous = releasesByGroup[key] ?? []
        let updated = previous.union(releaseIDs.map { $0.lowercased() })
        guard updated != previous else { return }
        objectWillChange.send()
        releasesByGroup[key] = updated
    }

    func releaseIDs(forArtist name: String) -> [String] {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return searchCatalog(query: .artists(matching: name), limit: Int.max)
            .map { $0.releaseID.lowercased() }
            .filter(MBIdentifiers.isMBID)
            .sorted()
    }

    /// Fetch only owned candidates for this artist, in bounded identifier-only
    /// batches. Titles and credit punctuation never establish group membership.
    func prepareReleaseMetadata(for releaseIDs: [String]) async {
        let missing = Array(Set(releaseIDs.map { $0.lowercased() }))
            .filter { MBIdentifiers.isMBID($0) && releaseMetadata[$0] == nil }
            .sorted()
        let batchSize = 25
        for start in stride(from: 0, to: missing.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let batch = Array(missing[start..<min(start + batchSize, missing.count)])
            let query = batch.map { "reid:\($0)" }.joined(separator: " OR ")
            do {
                let results = try await metadataService.searchReleases(
                    query: query, limit: batch.count, offset: 0
                )
                try Task.checkCancellation()
                let requested = Set(batch)
                for release in results where requested.contains(release.id.lowercased()) {
                    releaseMetadata[release.id.lowercased()] = release
                    if let group = release.releaseGroup {
                        rememberReleaseGroup(id: group.id, releaseIDs: [release.id])
                    }
                }
            } catch {
                // Optional enrichment must not block browsing or cache failures.
                return
            }
        }
    }

    func artistForLibraryCredit(_ row: SearchArtistRow) async -> MBArtist? {
        let releases = searchCatalog(query: .artists(matching: row.name), limit: Int.max)
            .filter { LibraryCatalogSearch.normalizedText($0.artistName)
                == LibraryCatalogSearch.normalizedText(row.name) }
        let ids = releases.map { $0.releaseID.lowercased() }
        await prepareReleaseMetadata(for: ids)
        guard !Task.isCancelled else { return nil }
        let artists = ids.flatMap { releaseMetadata[$0]?.artistCredit ?? [] }
            .compactMap(\.artist)
            .filter { MBIdentifiers.isMBID($0.id) }
        let unique = Dictionary(artists.map { ($0.id.lowercased(), $0) },
                                uniquingKeysWith: { first, _ in first }).values
        let query = LibraryCatalogSearch.normalizedText(row.librarySearchTerm ?? row.name)
        guard !query.isEmpty else { return nil }
        let exact = unique.filter { LibraryCatalogSearch.normalizedText($0.name) == query }
        if exact.count == 1 { return exact.first }
        // A partial query can select a credited artist only when unambiguous.
        let tokens = query.split(separator: " ").map(String.init)
        let matching = unique.filter { artist in
            let name = LibraryCatalogSearch.normalizedText(artist.name)
            return tokens.allSatisfy { name.contains($0) }
        }
        return matching.count == 1 ? matching.first : nil
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
