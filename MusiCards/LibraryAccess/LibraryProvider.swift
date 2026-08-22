import Combine
import Foundation

/// Source-specific availability lookup behind a source-independent boundary.
///
/// Stage 1 has only a Local implementation. Keeping the protocol synchronous
/// preserves the existing in-memory lookup behavior used while rendering rows.
@MainActor
protocol LibraryProvider: AnyObject {
    var source: LibrarySource { get }
    var catalogState: LibraryCatalogState { get }
    var catalogSummary: LibraryCatalogSummary { get }
    var availabilityChanges: AnyPublisher<Void, Never> { get }

    func refreshCatalog() async
    func refreshCatalogIfNeeded() async
    func searchCatalog(
        query: String,
        limit: Int
    ) -> [LibraryCatalogRelease]
    func prepareTrackAvailability(forRelease releaseID: String) async
    func containsRelease(_ releaseID: String) -> Bool
    func containsArtist(named artistName: String) -> Bool
    func containsReleaseGroup(title: String, artistName: String) -> Bool
    func containsTrack(_ identity: LibraryTrackIdentity) -> Bool
    func playableTrack(for identity: LibraryTrackIdentity) -> LibraryPlayableTrack?
    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource
}

extension LibraryProvider {
    func refreshCatalogIfNeeded() async {
        await refreshCatalog()
    }
}
