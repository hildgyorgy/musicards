import Combine
import Foundation
import XCTest
@testable import MusiCards

final class LibraryManagerTests: XCTestCase {
    @MainActor
    func testAvailabilityQueriesDelegateToProvider() {
        let provider = LibraryProviderSpy()
        provider.releaseIDs = ["release"]
        provider.artistNames = ["Artist"]
        provider.releaseGroups = ["Album::Artist"]
        provider.trackIdentities = [
            LibraryTrackIdentity(
                releaseID: "release",
                releaseTrackID: "release-track",
                recordingID: "recording",
                allowsRecordingFallback: true
            )
        ]
        let manager = LibraryManager(provider: provider)

        XCTAssertEqual(manager.source, .local)
        XCTAssertTrue(manager.containsRelease("release"))
        XCTAssertFalse(manager.containsRelease("other-release"))
        XCTAssertTrue(manager.containsArtist(named: "Artist"))
        XCTAssertTrue(
            manager.containsReleaseGroup(
                title: "Album",
                artistName: "Artist"
            )
        )
        XCTAssertTrue(
            manager.containsTrack(
                LibraryTrackIdentity(
                    releaseID: "release",
                    releaseTrackID: "release-track",
                    recordingID: "recording",
                    allowsRecordingFallback: true
                )
            )
        )
    }

    @MainActor
    func testSwitchingSourceChangesReleaseAvailabilityProvider() {
        let local = LibraryProviderSpy(source: .local)
        local.catalogSummary = LibraryCatalogSummary(
            identifiedAlbumCount: 2,
            totalAlbumCount: 3
        )
        local.releaseIDs = ["local-release"]
        let navidrome = LibraryProviderSpy(source: .navidrome)
        navidrome.catalogSummary = LibraryCatalogSummary(
            identifiedAlbumCount: 7,
            totalAlbumCount: 9
        )
        navidrome.releaseIDs = ["navidrome-release"]
        local.artistNames = ["Local Artist"]
        navidrome.artistNames = ["Navidrome Artist"]
        local.releaseGroups = ["Local Album::Local Artist"]
        navidrome.releaseGroups = ["Navidrome Album::Navidrome Artist"]
        let localTrack = LibraryTrackIdentity(
            releaseID: "local-release",
            releaseTrackID: "local-track",
            recordingID: "local-recording",
            allowsRecordingFallback: true
        )
        let navidromeTrack = LibraryTrackIdentity(
            releaseID: "navidrome-release",
            releaseTrackID: "navidrome-track",
            recordingID: "navidrome-recording",
            allowsRecordingFallback: true
        )
        local.trackIdentities = [localTrack]
        navidrome.trackIdentities = [navidromeTrack]
        let manager = LibraryManager(
            localProvider: local,
            navidromeProvider: navidrome
        )

        XCTAssertTrue(manager.containsRelease("local-release"))
        XCTAssertEqual(manager.catalogSummary, local.catalogSummary)
        XCTAssertFalse(manager.containsRelease("navidrome-release"))
        XCTAssertTrue(manager.containsTrack(localTrack))
        XCTAssertFalse(manager.containsTrack(navidromeTrack))
        XCTAssertTrue(manager.containsArtist(named: "Local Artist"))
        XCTAssertFalse(manager.containsArtist(named: "Navidrome Artist"))
        XCTAssertTrue(
            manager.containsReleaseGroup(
                title: "Local Album",
                artistName: "Local Artist"
            )
        )

        manager.setActiveSource(.navidrome)

        XCTAssertEqual(manager.source, .navidrome)
        XCTAssertFalse(manager.containsRelease("local-release"))
        XCTAssertTrue(manager.containsRelease("navidrome-release"))
        XCTAssertEqual(manager.catalogSummary, navidrome.catalogSummary)
        XCTAssertFalse(manager.containsTrack(localTrack))
        XCTAssertTrue(manager.containsTrack(navidromeTrack))
        XCTAssertFalse(manager.containsArtist(named: "Local Artist"))
        XCTAssertTrue(manager.containsArtist(named: "Navidrome Artist"))
        XCTAssertTrue(
            manager.containsReleaseGroup(
                title: "Navidrome Album",
                artistName: "Navidrome Artist"
            )
        )

        manager.setActiveSource(.local)

        XCTAssertEqual(manager.source, .local)
        XCTAssertTrue(manager.containsRelease("local-release"))
        XCTAssertTrue(manager.containsTrack(localTrack))
        XCTAssertFalse(manager.containsTrack(navidromeTrack))
        XCTAssertTrue(manager.containsArtist(named: "Local Artist"))
        XCTAssertFalse(manager.containsArtist(named: "Navidrome Artist"))
    }

    @MainActor
    func testSwitchingSourceChangesCatalogSearchProvider() {
        let local = LibraryProviderSpy(source: .local)
        local.catalogReleases = [
            LibraryCatalogRelease(
                releaseID: "local-release",
                title: "Shared Album",
                artistName: "Shared Artist"
            )
        ]
        let navidrome = LibraryProviderSpy(source: .navidrome)
        navidrome.catalogReleases = [
            LibraryCatalogRelease(
                releaseID: "navidrome-release",
                title: "Shared Album",
                artistName: "Shared Artist"
            )
        ]
        let manager = LibraryManager(
            localProvider: local,
            navidromeProvider: navidrome
        )

        XCTAssertEqual(
            manager.searchCatalog(query: "Shared Artist, Shared Album")
                .map(\.releaseID),
            ["local-release"]
        )

        manager.setActiveSource(.navidrome)

        XCTAssertEqual(
            manager.searchCatalog(query: "Shared Artist, Shared Album")
                .map(\.releaseID),
            ["navidrome-release"]
        )
    }

    @MainActor
    func testNavidromeRefreshRemainsBoundToSelectedProvider() async {
        let local = LibraryProviderSpy(source: .local)
        let navidrome = LibraryProviderSpy(source: .navidrome)
        let manager = LibraryManager(
            localProvider: local,
            navidromeProvider: navidrome
        )

        manager.setActiveSource(.navidrome)
        manager.setActiveSource(.local)
        await Task.yield()

        XCTAssertEqual(local.refreshCount, 0)
        XCTAssertEqual(navidrome.refreshCount, 1)
    }

    @MainActor
    func testForegroundRefreshUsesActiveLocalProvider() async {
        let local = LibraryProviderSpy(source: .local)
        let navidrome = LibraryProviderSpy(source: .navidrome)
        let manager = LibraryManager(
            localProvider: local,
            navidromeProvider: navidrome
        )

        await manager.refreshActiveCatalogIfNeeded()

        XCTAssertEqual(local.refreshIfNeededCount, 1)
        XCTAssertEqual(navidrome.refreshIfNeededCount, 0)
    }

    @MainActor
    func testForegroundRefreshUsesActiveNavidromeProvider() async {
        let local = LibraryProviderSpy(source: .local)
        let navidrome = LibraryProviderSpy(source: .navidrome)
        let manager = LibraryManager(
            localProvider: local,
            navidromeProvider: navidrome
        )
        manager.setActiveSource(.navidrome)

        await manager.refreshActiveCatalogIfNeeded()

        XCTAssertEqual(local.refreshIfNeededCount, 0)
        XCTAssertEqual(navidrome.refreshIfNeededCount, 1)
    }

    @MainActor
    func testReselectingUnknownNavidromeRetriesRefresh() async {
        let local = LibraryProviderSpy(source: .local)
        let navidrome = LibraryProviderSpy(source: .navidrome)
        navidrome.catalogState = .unknown
        let manager = LibraryManager(
            localProvider: local,
            navidromeProvider: navidrome
        )

        manager.setActiveSource(.navidrome)
        await Task.yield()
        manager.setActiveSource(.navidrome)
        await Task.yield()

        XCTAssertEqual(navidrome.refreshCount, 2)
    }

    @MainActor
    func testAssetResolutionUsesReferencedProviderAfterSourceSwitch() async throws {
        let local = LibraryProviderSpy(source: .local)
        let navidrome = LibraryProviderSpy(source: .navidrome)
        let localURL = URL(fileURLWithPath: "/tmp/local.flac")
        local.resolvedPlaybackSource = .localFile(localURL)
        let manager = LibraryManager(
            localProvider: local,
            navidromeProvider: navidrome
        )
        let reference = PlaybackAssetReference(
            source: .local,
            providerItemID: "local-file",
            displayName: "LOCAL"
        )

        manager.setActiveSource(.navidrome)
        let source = try await manager.resolvePlaybackAsset(reference)

        XCTAssertEqual(source, .localFile(localURL))
        XCTAssertEqual(local.resolvedReferences, [reference])
        XCTAssertTrue(navidrome.resolvedReferences.isEmpty)
    }
}

@MainActor
private final class LibraryProviderSpy: LibraryProvider {
    let source: LibrarySource
    var catalogState: LibraryCatalogState = .ready
    var catalogSummary = LibraryCatalogSummary()
    let availabilitySubject = PassthroughSubject<Void, Never>()
    var releaseIDs = Set<String>()
    var artistNames = Set<String>()
    var releaseGroups = Set<String>()
    var catalogReleases = [LibraryCatalogRelease]()
    var trackIdentities = Set<LibraryTrackIdentity>()
    var refreshCount = 0
    var refreshIfNeededCount = 0
    var resolvedPlaybackSource: PlaybackSource?
    var resolvedReferences = [PlaybackAssetReference]()

    var availabilityChanges: AnyPublisher<Void, Never> {
        availabilitySubject.eraseToAnyPublisher()
    }

    init(source: LibrarySource = .local) {
        self.source = source
    }

    func refreshCatalog() async {
        refreshCount += 1
    }

    func refreshCatalogIfNeeded() async {
        refreshIfNeededCount += 1
    }

    func searchCatalog(
        query: String,
        limit: Int
    ) -> [LibraryCatalogRelease] {
        LibraryCatalogSearch.search(
            catalogReleases,
            query: query,
            limit: limit
        )
    }

    func prepareTrackAvailability(forRelease releaseID: String) async {}

    func containsRelease(_ releaseID: String) -> Bool {
        releaseIDs.contains(releaseID)
    }

    func containsArtist(named artistName: String) -> Bool {
        artistNames.contains(artistName)
    }

    func containsReleaseGroup(title: String, artistName: String) -> Bool {
        releaseGroups.contains("\(title)::\(artistName)")
    }

    func containsTrack(_ identity: LibraryTrackIdentity) -> Bool {
        trackIdentities.contains(identity)
    }

    func playableTrack(
        for identity: LibraryTrackIdentity
    ) -> LibraryPlayableTrack? {
        nil
    }

    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource {
        resolvedReferences.append(reference)
        guard let resolvedPlaybackSource else {
            throw PlaybackAssetResolutionError.assetUnavailable
        }
        return resolvedPlaybackSource
    }
}
