import XCTest
@testable import MusiCards

final class RecentContentCacheTests: XCTestCase {
    @MainActor
    func testSnapshotsRoundTripAndPruningRemovesNonRecentEntries() async {
        let fileURL = temporaryCacheURL()
        let cache = RecentContentCache(fileURL: fileURL)

        await cache.save(
            RecentReleaseSnapshot(
                savedAt: Date(),
                release: Self.release(id: "release-a", title: "Cached release"),
                coverData: Data([1, 2, 3])
            ),
            for: "release-a"
        )
        await cache.save(
            RecentArtistSnapshot(
                savedAt: Date(),
                artist: Self.artist(id: "artist-a", name: "Cached artist"),
                name: "Cached artist",
                lifeSpan: "1980–",
                releaseGroups: [Self.group(id: "group-a")],
                hasMoreReleaseGroups: true,
                wikipediaTitle: "Cached artist",
                wikipediaExtract: "Cached summary"
            ),
            for: "artist-a"
        )

        let reloaded = RecentContentCache(fileURL: fileURL)
        let release = await reloaded.release(for: "release-a")
        let artist = await reloaded.artist(for: "artist-a")

        XCTAssertEqual(release?.release.title, "Cached release")
        XCTAssertEqual(release?.coverData, Data([1, 2, 3]))
        XCTAssertEqual(artist?.artist?.name, "Cached artist")
        XCTAssertEqual(artist?.releaseGroups.map(\.id), ["group-a"])
        XCTAssertEqual(artist?.wikipediaExtract, "Cached summary")

        await reloaded.retain(artistIDs: [], releaseIDs: [])
        let removedRelease = await reloaded.release(for: "release-a")
        let removedArtist = await reloaded.artist(for: "artist-a")
        XCTAssertNil(removedRelease)
        XCTAssertNil(removedArtist)
    }

    @MainActor
    func testCachedReleaseAppearsBeforeNetworkRefreshCompletes() async {
        let cache = RecentContentCache(fileURL: temporaryCacheURL())
        await cache.save(
            RecentReleaseSnapshot(
                savedAt: Date(),
                release: Self.release(id: "cached-release", title: "Cached title"),
                coverData: nil
            ),
            for: "cached-release"
        )
        let model = MusiCardsAppModel(
            playbackEngine: PendingPlaybackEngine(),
            releaseDetailLoader: { id in
                if id == "cached-release" {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                }
                return Self.release(id: id, title: "Network title")
            },
            releaseCoverLoader: { _ in nil },
            recentContentCache: cache
        )

        model.selectRelease(Self.releaseRow(id: "cached-release"))

        await eventually {
            model.selectedRelease?.title == "Cached title"
                && !model.isLoadingRelease
        }
        XCTAssertNil(model.releaseError)

        model.selectRelease(Self.releaseRow(id: "cancel-refresh"))
    }

    @MainActor
    func testCachedArtistAppearsBeforeNetworkRefreshCompletes() async {
        let cache = RecentContentCache(fileURL: temporaryCacheURL())
        await cache.save(
            RecentArtistSnapshot(
                savedAt: Date(),
                artist: Self.artist(id: "cached-artist", name: "Cached artist"),
                name: "Cached artist",
                lifeSpan: "1980–",
                releaseGroups: [Self.group(id: "cached-group")],
                hasMoreReleaseGroups: true,
                wikipediaTitle: "Cached artist",
                wikipediaExtract: "Cached summary"
            ),
            for: "cached-artist"
        )
        let model = MusiCardsAppModel(
            playbackEngine: PendingPlaybackEngine(),
            releaseDetailLoader: { id in Self.release(id: id, title: id) },
            releaseCoverLoader: { _ in nil },
            artistDetailLoader: { id in
                Self.artist(id: id, name: "Network artist")
            },
            artistReleaseGroupsLoader: { id, _, _ in
                if id == "cached-artist" {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                }
                return ([], false)
            },
            artistWikipediaLoader: { _ in nil },
            recentContentCache: cache
        )

        model.selectArtist(id: "cached-artist")

        await eventually {
            model.selectedArtistName == "Cached artist"
                && model.artistReleaseGroups.map(\.id) == ["cached-group"]
                && model.artistWikipedia?.extract == "Cached summary"
        }

        model.selectArtist(id: "cancel-refresh")
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("RecentContent.json")
    }

    private nonisolated static func release(
        id: String,
        title: String
    ) -> MBRelease {
        MBRelease(
            id: id,
            title: title,
            artistCredit: nil,
            date: nil,
            country: nil,
            barcode: nil,
            disambiguation: nil,
            labelInfo: nil,
            media: nil,
            releaseGroup: nil,
            relations: nil,
            annotation: nil
        )
    }

    private nonisolated static func artist(
        id: String,
        name: String
    ) -> MBArtistDetail {
        MBArtistDetail(
            id: id,
            name: name,
            disambiguation: nil,
            country: nil,
            type: nil,
            lifeSpan: nil,
            beginArea: nil,
            endArea: nil,
            relations: nil
        )
    }

    private nonisolated static func group(id: String) -> MBReleaseGroupSummary {
        MBReleaseGroupSummary(
            id: id,
            title: "Group",
            primaryType: "Album",
            secondaryTypes: nil,
            firstReleaseDate: "2020",
            disambiguation: nil
        )
    }

    private nonisolated static func releaseRow(id: String) -> SearchReleaseRow {
        SearchReleaseRow(
            id: id,
            title: id,
            artistLine: "Artist",
            metaLine: "",
            disambiguation: "",
            hasCoverArt: false
        )
    }

    @MainActor
    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}
