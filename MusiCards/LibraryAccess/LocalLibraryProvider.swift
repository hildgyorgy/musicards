import Combine
import Foundation

/// Thin adapter that leaves LocalLibraryStore and its matching policy intact.
@MainActor
final class LocalLibraryProvider: LibraryProvider {
    let source: LibrarySource = .local
    let catalogState: LibraryCatalogState = .ready

    private let store: LocalLibraryStore

    init(store: LocalLibraryStore) {
        self.store = store
    }

    var availabilityChanges: AnyPublisher<Void, Never> {
        store.objectWillChange.eraseToAnyPublisher()
    }

    var catalogSummary: LibraryCatalogSummary {
        LibraryCatalogSummary(
            identifiedAlbumCount: store.summary.identifiedAlbumCount,
            totalAlbumCount: store.summary.totalAlbumCount
        )
    }

    func refreshCatalog() async {
        // LocalLibraryStore continues to own its existing refresh lifecycle.
    }

    func refreshCatalogIfNeeded() async {
        store.refreshIfNeeded()
    }

    func searchCatalog(
        query: String,
        limit: Int
    ) -> [LibraryCatalogRelease] {
        store.searchCatalog(query: query, limit: limit)
    }

    func prepareTrackAvailability(forRelease releaseID: String) async {
        // LocalLibraryStore already keeps its track lookup ready in memory.
    }

    func containsRelease(_ releaseID: String) -> Bool {
        store.containsRelease(releaseID)
    }

    func containsArtist(named artistName: String) -> Bool {
        store.containsArtist(named: artistName)
    }

    func containsReleaseGroup(title: String, artistName: String) -> Bool {
        store.containsReleaseGroup(title: title, artistName: artistName)
    }

    func containsTrack(_ identity: LibraryTrackIdentity) -> Bool {
        store.containsTrack(
            releaseID: identity.releaseID,
            releaseTrackID: identity.releaseTrackID,
            recordingID: identity.recordingID,
            allowsRecordingFallback: identity.allowsRecordingFallback
        )
    }

    func playableTrack(
        for identity: LibraryTrackIdentity
    ) -> LibraryPlayableTrack? {
        guard let file = store.audioFile(
            releaseID: identity.releaseID,
            releaseTrackID: identity.releaseTrackID,
            recordingID: identity.recordingID,
            allowsRecordingFallback: identity.allowsRecordingFallback
        ), let url = store.url(for: file) else {
            return nil
        }

        return LibraryPlayableTrack(
            id: file.id,
            releaseTrackID: file.releaseTrackMBID,
            recordingID: file.recordingMBID,
            releaseID: file.releaseMBID,
            fallbackArtist: file.artist,
            duration: file.duration,
            audioFormat: PlaybackAudioFormat(
                codec: file.codec,
                bitDepth: file.bitDepth,
                sampleRate: file.sampleRate,
                bitrate: file.bitrate,
                channelCount: file.channelCount
            ),
            assetReference: PlaybackAssetReference(
                source: source,
                providerItemID: file.id,
                displayName: Self.assetDisplayName(for: url)
            )
        )
    }

    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource {
        guard reference.source == source,
              let file = store.audioFile(id: reference.providerItemID),
              let url = store.url(for: file) else {
            throw PlaybackAssetResolutionError.assetUnavailable
        }
        return .localFile(url)
    }

    private static func assetDisplayName(for url: URL) -> String {
        let path = url.absoluteString.lowercased()
        if path.contains("dropbox") {
            return "DROPBOX"
        }
        if path.contains("icloud") || path.contains("ubiquity") {
            return "ICLOUD"
        }
        return "LOCAL"
    }
}
