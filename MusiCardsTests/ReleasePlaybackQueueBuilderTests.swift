import Combine
import Foundation
import XCTest
@testable import MusiCards

final class ReleasePlaybackQueueBuilderTests: XCTestCase {
    @MainActor
    func testBuildPreservesLocalQueueMetadataAndUsesOpaqueAssets() async throws {
        let release = try makeRelease()
        let provider = QueueLibraryProvider()
        let firstReference = PlaybackAssetReference(
            source: .local,
            providerItemID: "file-1",
            displayName: "LOCAL"
        )
        let secondReference = PlaybackAssetReference(
            source: .local,
            providerItemID: "file-2",
            displayName: "DROPBOX"
        )
        let format = PlaybackAudioFormat(
            codec: "flac",
            bitDepth: 24,
            sampleRate: 96_000,
            bitrate: 2_000_000,
            channelCount: 2
        )
        provider.playableTracks = [
            "release-track-1": LibraryPlayableTrack(
                id: "file-1",
                releaseTrackID: "release-track-1",
                recordingID: "recording-1",
                releaseID: "release-1",
                fallbackArtist: "File Artist",
                duration: 181,
                audioFormat: format,
                assetReference: firstReference
            ),
            "release-track-2": LibraryPlayableTrack(
                id: "file-2",
                releaseTrackID: nil,
                recordingID: "recording-2",
                releaseID: "release-1",
                fallbackArtist: "File Artist",
                duration: nil,
                audioFormat: format,
                assetReference: secondReference
            )
        ]
        let manager = LibraryManager(provider: provider)
        let builder = ReleasePlaybackQueueBuilder(libraryManager: manager)
        let selection = ReleasePlaybackSelection(
            releaseTrackID: "release-track-2",
            recordingID: "recording-2"
        )

        let builtQueue = await builder.buildQueue(
            for: release,
            selection: selection
        )
        let queue = try XCTUnwrap(builtQueue)

        XCTAssertEqual(queue.selectedIndex, 1)
        XCTAssertEqual(queue.items.count, 2)
        XCTAssertTrue(provider.resolvedReferences.isEmpty)

        let first = queue.items[0]
        XCTAssertEqual(first.id, "file-1")
        XCTAssertEqual(first.source, .libraryAsset(firstReference))
        XCTAssertEqual(first.track.releaseTrackID, "release-track-1")
        XCTAssertEqual(first.track.recordingID, "recording-1")
        XCTAssertEqual(first.track.releaseID, "release-1")
        XCTAssertEqual(first.track.title, "First Track")
        XCTAssertEqual(first.track.artist, "Release Artist")
        XCTAssertEqual(first.track.albumTitle, "Release Title")
        XCTAssertEqual(first.track.duration, 181)
        XCTAssertNil(first.track.artworkData)
        XCTAssertEqual(first.track.mediumFormat, "CD")
        XCTAssertEqual(first.track.discNumber, 1)
        XCTAssertEqual(first.track.trackNumber, 1)
        XCTAssertEqual(first.track.audioFormat, format)

        let second = queue.items[1]
        XCTAssertEqual(second.source, .libraryAsset(secondReference))
        XCTAssertEqual(second.track.releaseTrackID, "release-track-2")
        XCTAssertEqual(second.track.duration, 200)
    }

    @MainActor
    func testFirstPlayableSelectionUsesProviderMatches() throws {
        let release = try makeRelease()
        let provider = QueueLibraryProvider()
        provider.playableTracks = [
            "release-track-2": LibraryPlayableTrack(
                id: "file-2",
                releaseTrackID: "release-track-2",
                recordingID: "recording-2",
                releaseID: "release-1",
                fallbackArtist: "Artist",
                duration: nil,
                audioFormat: nil,
                assetReference: PlaybackAssetReference(
                    source: .local,
                    providerItemID: "file-2",
                    displayName: "LOCAL"
                )
            )
        ]
        let manager = LibraryManager(provider: provider)
        let builder = ReleasePlaybackQueueBuilder(libraryManager: manager)

        XCTAssertEqual(
            builder.firstPlayableSelection(in: release),
            ReleasePlaybackSelection(
                releaseTrackID: "release-track-2",
                recordingID: "recording-2"
            )
        )
    }

    @MainActor
    func testQueueRemainsBoundToRequestedProvider() async throws {
        let release = try makeRelease()
        let local = QueueLibraryProvider(source: .local)
        let navidrome = QueueLibraryProvider(source: .navidrome)
        let navidromeReference = PlaybackAssetReference(
            source: .navidrome,
            providerItemID: "navidrome-song",
            displayName: "NAVIDROME"
        )
        navidrome.playableTracks = [
            "release-track-1": LibraryPlayableTrack(
                id: "navidrome-song",
                releaseTrackID: "release-track-1",
                recordingID: "recording-1",
                releaseID: "release-1",
                fallbackArtist: "Release Artist",
                duration: 180,
                audioFormat: nil,
                assetReference: navidromeReference
            )
        ]
        let manager = LibraryManager(
            localProvider: local,
            navidromeProvider: navidrome
        )
        let builder = ReleasePlaybackQueueBuilder(libraryManager: manager)

        let queue = await builder.buildQueue(
            for: release,
            selection: ReleasePlaybackSelection(
                releaseTrackID: "release-track-1",
                recordingID: "recording-1"
            ),
            source: .navidrome
        )

        XCTAssertEqual(manager.source, .local)
        XCTAssertEqual(
            queue?.items.first?.source,
            .libraryAsset(navidromeReference)
        )
    }

    @MainActor
    private func makeRelease() throws -> MBRelease {
        try JSONDecoder().decode(
            MBRelease.self,
            from: Data(
                """
                {
                  "id": "release-1",
                  "title": "Release Title",
                  "artist-credit": [{"name": "Release Artist"}],
                  "media": [{
                    "position": 1,
                    "format": "CD",
                    "tracks": [{
                      "id": "release-track-1",
                      "position": 1,
                      "title": "First Track",
                      "length": 180000,
                      "recording": {"id": "recording-1"}
                    }, {
                      "id": "release-track-2",
                      "position": 2,
                      "title": "Second Track",
                      "length": 200000,
                      "recording": {"id": "recording-2"}
                    }]
                  }]
                }
                """.utf8
            )
        )
    }
}

@MainActor
private final class QueueLibraryProvider: LibraryProvider {
    let source: LibrarySource
    let catalogState: LibraryCatalogState = .ready
    let catalogSummary = LibraryCatalogSummary()
    let availabilitySubject = PassthroughSubject<Void, Never>()
    var playableTracks = [String: LibraryPlayableTrack]()
    var resolvedSources = [PlaybackAssetReference: PlaybackSource]()
    var resolvedReferences = [PlaybackAssetReference]()

    init(source: LibrarySource = .local) {
        self.source = source
    }

    var availabilityChanges: AnyPublisher<Void, Never> {
        availabilitySubject.eraseToAnyPublisher()
    }

    func refreshCatalog() async {}

    func searchCatalog(
        query: String,
        limit: Int
    ) -> [LibraryCatalogRelease] {
        []
    }
    func prepareTrackAvailability(forRelease releaseID: String) async {}
    func containsRelease(_ releaseID: String) -> Bool { false }
    func containsArtist(named artistName: String) -> Bool { false }
    func containsReleaseGroup(title: String, artistName: String) -> Bool { false }

    func containsTrack(_ identity: LibraryTrackIdentity) -> Bool {
        playableTrack(for: identity) != nil
    }

    func playableTrack(
        for identity: LibraryTrackIdentity
    ) -> LibraryPlayableTrack? {
        guard let releaseTrackID = identity.releaseTrackID else { return nil }
        return playableTracks[releaseTrackID]
    }

    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource {
        resolvedReferences.append(reference)
        guard let source = resolvedSources[reference] else {
            throw PlaybackAssetResolutionError.assetUnavailable
        }
        return source
    }
}
