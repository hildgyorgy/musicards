import Foundation
import XCTest
@testable import MusiCards

final class NavidromeLibraryProviderTests: XCTestCase {
    private let listReleaseID = "189002e7-3285-4e2e-92a3-7f6c30d407a2"
    private let uniqueRecordingID = "bf99cae5-3b83-437a-a266-7126bd5653bf"
    private let duplicateRecordingID = "f2897e08-8d2f-4d32-9a9f-3ed062f67793"

    @MainActor
    func testRefreshUsesOnlyPaginatedAlbumListMBIDs() async {
        let connection = CatalogConnectionStub()
        let client = CatalogClientStub(
            pages: [
                0: [
                    album(id: "one", musicBrainzID: listReleaseID),
                    album(id: "two", musicBrainzID: nil)
                ],
                2: [album(id: "three", musicBrainzID: "not-an-mbid")]
            ]
        )
        let provider = NavidromeLibraryProvider(
            connection: connection,
            client: client,
            pageSize: 2
        )

        XCTAssertEqual(provider.catalogState, .unknown)

        await provider.refreshCatalog()

        XCTAssertEqual(provider.catalogState, .ready)
        XCTAssertTrue(provider.containsRelease(listReleaseID))
        XCTAssertFalse(provider.containsRelease("not-an-mbid"))
        XCTAssertFalse(provider.containsRelease("Album title"))
        XCTAssertEqual(
            provider.catalogSummary,
            LibraryCatalogSummary(
                identifiedAlbumCount: 1,
                totalAlbumCount: 3
            )
        )
        let requestedOffsets = await client.requestedOffsets()
        let requestedDetailIDs = await client.requestedDetailIDs()
        XCTAssertEqual(requestedOffsets, [0, 2])
        XCTAssertTrue(requestedDetailIDs.isEmpty)
    }

    @MainActor
    func testFailedRefreshKeepsUnknownStateDistinctFromUnavailableRelease() async {
        let provider = NavidromeLibraryProvider(
            connection: CatalogConnectionStub(),
            client: CatalogClientStub(error: CatalogTestError.failed)
        )

        XCTAssertFalse(provider.containsRelease(listReleaseID))
        XCTAssertEqual(provider.catalogState, .unknown)

        await provider.refreshCatalog()

        guard case .failed = provider.catalogState else {
            return XCTFail("Expected a failed catalog state")
        }
        XCTAssertFalse(provider.containsRelease(listReleaseID))
    }

    @MainActor
    func testForegroundRefreshSkipsFreshCatalogAndReloadsStaleCatalog() async {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let client = CatalogClientStub(
            pages: [
                0: [album(id: "one", musicBrainzID: listReleaseID)]
            ]
        )
        let provider = NavidromeLibraryProvider(
            connection: CatalogConnectionStub(),
            client: client,
            foregroundRefreshInterval: 60,
            now: { currentDate }
        )

        await provider.refreshCatalog()
        await provider.refreshCatalogIfNeeded()
        var requestedOffsets = await client.requestedOffsets()
        XCTAssertEqual(requestedOffsets, [0])

        currentDate.addTimeInterval(61)
        await provider.refreshCatalogIfNeeded()
        requestedOffsets = await client.requestedOffsets()
        XCTAssertEqual(requestedOffsets, [0, 0])
    }

    @MainActor
    func testConcurrentForegroundRefreshesShareOneCatalogLoad() async {
        let client = CatalogClientStub(
            pages: [
                0: [album(id: "one", musicBrainzID: listReleaseID)]
            ],
            delayNanoseconds: 50_000_000
        )
        let provider = NavidromeLibraryProvider(
            connection: CatalogConnectionStub(),
            client: client,
            foregroundRefreshInterval: 0
        )

        async let first: Void = provider.refreshCatalogIfNeeded()
        async let second: Void = provider.refreshCatalogIfNeeded()
        _ = await (first, second)

        let requestedOffsets = await client.requestedOffsets()
        XCTAssertEqual(requestedOffsets, [0])
    }

    @MainActor
    func testFailedForegroundRefreshKeepsPreviouslyValidCatalog() async {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let client = CatalogClientStub(
            pages: [
                0: [album(id: "one", musicBrainzID: listReleaseID)]
            ]
        )
        let provider = NavidromeLibraryProvider(
            connection: CatalogConnectionStub(),
            client: client,
            foregroundRefreshInterval: 60,
            now: { currentDate }
        )

        await provider.refreshCatalog()
        let validSummary = provider.catalogSummary
        await client.setError(CatalogTestError.failed)
        currentDate.addTimeInterval(61)

        await provider.refreshCatalogIfNeeded()

        XCTAssertEqual(provider.catalogState, .ready)
        XCTAssertEqual(provider.catalogSummary, validSummary)
        XCTAssertTrue(provider.containsRelease(listReleaseID))
    }

    @MainActor
    func testTrackAvailabilityUsesUniqueRecordingsWithinMatchedRelease() async throws {
        let client = CatalogClientStub(
            pages: [
                0: [album(id: "one", musicBrainzID: listReleaseID)]
            ],
            details: [
                "one": album(
                    id: "one",
                    musicBrainzID: listReleaseID,
                    songs: [
                        song(
                            id: "unique",
                            musicBrainzID: uniqueRecordingID,
                            title: "Playable Track",
                            suffix: "flac",
                            contentType: "audio/flac",
                            size: 20_000_000,
                            duration: 180
                        ),
                        song(id: "duplicate-1", musicBrainzID: duplicateRecordingID),
                        song(id: "duplicate-2", musicBrainzID: duplicateRecordingID),
                        song(id: "missing", musicBrainzID: nil)
                    ]
                )
            ]
        )
        let provider = NavidromeLibraryProvider(
            connection: CatalogConnectionStub(),
            client: client
        )

        await provider.refreshCatalog()
        XCTAssertFalse(
            provider.containsTrack(
                trackIdentity(recordingID: uniqueRecordingID)
            )
        )

        let releaseID = listReleaseID
        async let firstLoad: Void = provider.prepareTrackAvailability(
            forRelease: releaseID
        )
        async let duplicateLoad: Void = provider.prepareTrackAvailability(
            forRelease: releaseID
        )
        _ = await (firstLoad, duplicateLoad)

        XCTAssertTrue(
            provider.containsTrack(
                trackIdentity(recordingID: uniqueRecordingID)
            )
        )
        let playableTrack = provider.playableTrack(
            for: trackIdentity(recordingID: uniqueRecordingID)
        )
        XCTAssertEqual(playableTrack?.id, "unique")
        XCTAssertEqual(playableTrack?.duration, 180)
        let reference = try XCTUnwrap(playableTrack?.assetReference)
        XCTAssertEqual(reference.seekCapability, .unsupported)
        let source = try await provider.resolvePlaybackAsset(reference)
        guard case .remoteAudio(let asset) = source else {
            return XCTFail("Expected a provider-owned remote playback asset")
        }
        XCTAssertEqual(asset.source, .navidrome)
        XCTAssertEqual(asset.providerItemID, "unique")
        XCTAssertEqual(asset.mediaSize, 20_000_000)
        XCTAssertEqual(asset.suffix, "flac")
        XCTAssertEqual(asset.seekCapability, .unsupported)
        XCTAssertFalse(
            provider.containsTrack(
                trackIdentity(recordingID: duplicateRecordingID)
            )
        )
        XCTAssertFalse(
            provider.containsTrack(
                trackIdentity(recordingID: nil)
            )
        )
        XCTAssertFalse(
            provider.containsTrack(
                trackIdentity(
                    recordingID: uniqueRecordingID,
                    allowsRecordingFallback: false
                )
            )
        )

        await provider.prepareTrackAvailability(forRelease: listReleaseID)
        let requestedDetailIDs = await client.requestedDetailIDs()
        XCTAssertEqual(requestedDetailIDs, ["one"])
    }

    @MainActor
    func testTrackAvailabilityDoesNotGuessBetweenDuplicateReleaseAlbums() async {
        let client = CatalogClientStub(
            pages: [
                0: [
                    album(id: "one", musicBrainzID: listReleaseID),
                    album(id: "two", musicBrainzID: listReleaseID)
                ]
            ],
            details: [
                "one": album(
                    id: "one",
                    musicBrainzID: listReleaseID,
                    songs: [song(id: "song", musicBrainzID: uniqueRecordingID)]
                )
            ]
        )
        let provider = NavidromeLibraryProvider(
            connection: CatalogConnectionStub(),
            client: client
        )

        await provider.refreshCatalog()
        await provider.prepareTrackAvailability(forRelease: listReleaseID)

        XCTAssertTrue(provider.containsRelease(listReleaseID))
        XCTAssertFalse(
            provider.containsTrack(
                trackIdentity(recordingID: uniqueRecordingID)
            )
        )
        let requestedDetailIDs = await client.requestedDetailIDs()
        XCTAssertTrue(requestedDetailIDs.isEmpty)
    }

    @MainActor
    func testArtistAndReleaseGroupAvailabilityUsesCatalogCredits() async {
        let client = CatalogClientStub(
            pages: [
                0: [
                    album(
                        id: "matched",
                        name: "Café Blue",
                        musicBrainzID: listReleaseID,
                        artist: "Patrícia Barber feat. Guest",
                        artists: [
                            artist(id: "patricia", name: "Patrícia Barber"),
                            artist(id: "guest", name: "Guest")
                        ]
                    ),
                    album(
                        id: "untagged",
                        name: "Catalog Only Album",
                        musicBrainzID: nil,
                        artist: "Catalog Only Artist"
                    )
                ]
            ],
            details: [
                "untagged": album(
                    id: "untagged",
                    name: "Catalog Only Album",
                    musicBrainzID: nil,
                    artist: "Catalog Only Artist"
                )
            ]
        )
        let provider = NavidromeLibraryProvider(
            connection: CatalogConnectionStub(),
            client: client
        )

        await provider.refreshCatalog()

        XCTAssertTrue(provider.containsArtist(named: "Patricia Barber"))
        XCTAssertTrue(provider.containsArtist(named: "Guest"))
        XCTAssertTrue(provider.containsArtist(named: "Catalog Only Artist"))
        XCTAssertFalse(provider.containsArtist(named: "Patricia"))
        XCTAssertFalse(provider.containsArtist(named: "Barber"))
        XCTAssertTrue(
            provider.containsReleaseGroup(
                title: "Cafe Blue",
                artistName: "Patricia Barber"
            )
        )
        XCTAssertTrue(
            provider.containsReleaseGroup(
                title: "Café Blue",
                artistName: "Guest"
            )
        )
        XCTAssertFalse(
            provider.containsReleaseGroup(
                title: "Cafe",
                artistName: "Patricia Barber"
            )
        )
        XCTAssertFalse(
            provider.containsReleaseGroup(
                title: "Catalog Only Album",
                artistName: "Catalog Only Artist"
            )
        )
    }

    @MainActor
    func testCatalogSearchUsesRefreshedAlbumsWithoutPerRowRequests() async {
        let client = CatalogClientStub(
            pages: [
                0: [
                    album(
                        id: "nevermind",
                        name: "Nevermind",
                        musicBrainzID: listReleaseID,
                        artist: "Nirvána",
                        songs: [
                            song(
                                id: "song",
                                musicBrainzID: uniqueRecordingID,
                                title: "Smells Like Teen Spirit",
                                suffix: "flac"
                            )
                        ]
                    ),
                    album(
                        id: "untagged",
                        name: "Nevermind",
                        musicBrainzID: nil,
                        artist: "Nirvana"
                    )
                ]
            ],
            details: [
                "untagged": album(
                    id: "untagged",
                    name: "Nevermind",
                    musicBrainzID: nil,
                    artist: "Nirvana"
                )
            ]
        )
        let provider = NavidromeLibraryProvider(
            connection: CatalogConnectionStub(),
            client: client
        )

        XCTAssertTrue(
            provider.searchCatalog(query: "Nirvana, Nevermind", limit: 50)
                .isEmpty
        )
        await provider.refreshCatalog()
        let detailRequestsAfterRefresh = await client.requestedDetailIDs()

        let releaseMatches = provider.searchCatalog(
            query: "Nirvana, Never-mind",
            limit: 50
        )
        let trackMatches = provider.searchCatalog(
            query: "Nirvana, Teen Spirit",
            limit: 50
        )
        let detailRequestsAfterSearch = await client.requestedDetailIDs()

        XCTAssertEqual(releaseMatches.map(\.releaseID), [listReleaseID])
        XCTAssertEqual(trackMatches.map(\.releaseID), [listReleaseID])
        XCTAssertEqual(detailRequestsAfterSearch, detailRequestsAfterRefresh)
    }

    private func album(
        id: String,
        name: String? = nil,
        musicBrainzID: String?,
        artist: String? = nil,
        artists: [OpenSubsonicArtist] = [],
        songs: [OpenSubsonicSong] = []
    ) -> OpenSubsonicAlbum {
        OpenSubsonicAlbum(
            id: id,
            name: name ?? "Album \(id)",
            musicBrainzID: musicBrainzID,
            artist: artist,
            artists: artists,
            songs: songs
        )
    }

    private func artist(id: String, name: String) -> OpenSubsonicArtist {
        OpenSubsonicArtist(id: id, name: name)
    }

    private func song(
        id: String,
        musicBrainzID: String?,
        title: String? = nil,
        suffix: String? = nil,
        contentType: String? = nil,
        size: Int64? = nil,
        duration: Int? = nil
    ) -> OpenSubsonicSong {
        OpenSubsonicSong(
            id: id,
            musicBrainzID: musicBrainzID,
            title: title,
            suffix: suffix,
            contentType: contentType,
            size: size,
            duration: duration
        )
    }

    private func trackIdentity(
        recordingID: String?,
        allowsRecordingFallback: Bool = true
    ) -> LibraryTrackIdentity {
        LibraryTrackIdentity(
            releaseID: listReleaseID,
            releaseTrackID: "release-track",
            recordingID: recordingID,
            allowsRecordingFallback: allowsRecordingFallback
        )
    }
}

@MainActor
private final class CatalogConnectionStub: NavidromeCatalogConnectionProviding {
    func catalogCredentials() throws -> NavidromeCatalogCredentials {
        NavidromeCatalogCredentials(
            profile: NavidromeServerProfile(
                name: "Test",
                baseURL: URL(string: "https://music.example.com")!,
                username: "listener"
            ),
            password: "password"
        )
    }
}

private actor CatalogClientStub: OpenSubsonicCatalogClientProtocol {
    private let pages: [Int: [OpenSubsonicAlbum]]
    private let details: [String: OpenSubsonicAlbum]
    private var error: Error?
    private let delayNanoseconds: UInt64
    private var offsets = [Int]()
    private var detailIDs = [String]()

    init(
        pages: [Int: [OpenSubsonicAlbum]] = [:],
        details: [String: OpenSubsonicAlbum] = [:],
        error: Error? = nil,
        delayNanoseconds: UInt64 = 0
    ) {
        self.pages = pages
        self.details = details
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    func albumListPage(
        profile: NavidromeServerProfile,
        password: String,
        offset: Int,
        size: Int
    ) async throws -> [OpenSubsonicAlbum] {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error { throw error }
        offsets.append(offset)
        return pages[offset] ?? []
    }

    func album(
        profile: NavidromeServerProfile,
        password: String,
        id: String
    ) async throws -> OpenSubsonicAlbum {
        detailIDs.append(id)
        guard let album = details[id] else { throw CatalogTestError.failed }
        return album
    }

    func requestedOffsets() -> [Int] {
        offsets
    }

    func requestedDetailIDs() -> [String] {
        detailIDs
    }

    func setError(_ error: Error?) {
        self.error = error
    }
}

private enum CatalogTestError: LocalizedError {
    case failed

    var errorDescription: String? { "Catalog failed" }
}
