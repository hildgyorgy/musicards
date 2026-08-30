import XCTest
@testable import MusiCards

@MainActor
final class ArtistIndependentLoadingTests: XCTestCase {
    func testWikipediaPublishesWhileDiscographyIsStillLoading() async throws {
        let discographyGate = AsyncGate()
        let model = makeModel(
            artistDetailLoader: { _ in await Self.artistWithWikidata() },
            artistReleaseGroupsLoader: { _, _, _ in
                await discographyGate.wait()
                return ([Self.releaseGroup()], false)
            },
            artistWikipediaLoader: { _ in Self.wikipediaSummary() }
        )

        model.selectArtist(Self.artistRow())

        await eventually {
            model.artistWikipedia?.extract == "Wikipedia summary"
                && model.isLoadingArtistDiscography
                && model.artistReleaseGroups.isEmpty
        }

        await discographyGate.open()
        await eventually {
            model.artistReleaseGroups.map(\.id) == ["group-id"]
                && !model.isLoadingArtistDiscography
        }
    }

    func testWikipediaFailureHasDedicatedRetryWithoutReloadingDiscography() async {
        let wikipediaLoader = WikipediaLoaderProbe()
        let discographyLoader = DiscographyLoaderProbe()
        let model = makeModel(
            artistDetailLoader: { _ in await Self.artistWithWikidata() },
            artistReleaseGroupsLoader: { _, _, _ in
                await discographyLoader.load()
            },
            artistWikipediaLoader: { _ in
                try await wikipediaLoader.load()
            }
        )

        model.selectArtist(Self.artistRow())
        await eventually {
            model.artistWikipediaError != nil
                && !model.isLoadingArtistWikipedia
                && model.artistReleaseGroups.count == 1
        }

        model.retryArtistWikipedia()
        await eventually {
            model.artistWikipedia?.extract == "Wikipedia summary"
                && model.artistWikipediaError == nil
        }

        let wikipediaCallCount = await wikipediaLoader.callCount
        let discographyCallCount = await discographyLoader.callCount
        XCTAssertEqual(wikipediaCallCount, 2)
        XCTAssertEqual(discographyCallCount, 1)
    }

    func testMissingWikidataRelationIsCompletedUnavailableNotFailure() async {
        let model = makeModel(
            artistDetailLoader: { _ in await Self.artistWithoutWikidata() },
            artistReleaseGroupsLoader: { _, _, _ in ([], false) },
            artistWikipediaLoader: { _ in
                XCTFail("Wikipedia must not be requested without a Wikidata relation")
                return nil
            }
        )

        model.selectArtist(Self.artistRow())
        await eventually {
            model.isArtistWikipediaUnavailable
                && !model.isLoadingArtistWikipedia
                && !model.isLoadingArtistDiscography
        }

        XCTAssertNil(model.artistWikipedia)
        XCTAssertNil(model.artistWikipediaError)
        XCTAssertTrue(model.artistReleaseGroups.isEmpty)
        XCTAssertNil(model.discographyError)
    }

    private func makeModel(
        artistDetailLoader:
            @escaping @Sendable (String) async throws -> MBArtistDetail,
        artistReleaseGroupsLoader:
            @escaping @Sendable (String, Int, Int) async throws
            -> (groups: [MBReleaseGroupSummary], hasMore: Bool),
        artistWikipediaLoader:
            @escaping @Sendable (URL) async throws -> WikipediaSummary?
    ) -> MusiCardsAppModel {
        MusiCardsAppModel(
            playbackEngine: PendingPlaybackEngine(),
            releaseDetailLoader: { id in Self.release(id: id) },
            releaseCoverLoader: { _ in nil },
            artistDetailLoader: artistDetailLoader,
            artistReleaseGroupsLoader: artistReleaseGroupsLoader,
            artistWikipediaLoader: artistWikipediaLoader,
            recentContentCache: RecentContentCache(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent("RecentContent.json")
            )
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    nonisolated private static func artistRow() -> SearchArtistRow {
        SearchArtistRow(
            id: "artist-id",
            name: "Example Artist",
            lifeSpan: "1970–"
        )
    }

    private static func artistWithWikidata() -> MBArtistDetail {
        MBArtistDetail(
            id: "artist-id",
            name: "Example Artist",
            disambiguation: nil,
            country: nil,
            type: nil,
            lifeSpan: nil,
            beginArea: nil,
            endArea: nil,
            relations: [
                MBRelation(
                    type: "wikidata",
                    url: MBRelationURL(
                        resource: "https://www.wikidata.org/wiki/Q1"
                    )
                )
            ]
        )
    }

    private static func artistWithoutWikidata() -> MBArtistDetail {
        MBArtistDetail(
            id: "artist-id",
            name: "Example Artist",
            disambiguation: nil,
            country: nil,
            type: nil,
            lifeSpan: nil,
            beginArea: nil,
            endArea: nil,
            relations: []
        )
    }

    nonisolated private static func wikipediaSummary() -> WikipediaSummary {
        WikipediaSummary(
            title: "Example Artist",
            extract: "Wikipedia summary",
            languageCode: "en",
            pageURL: URL(string: "https://en.wikipedia.org/wiki/Example_Artist")!
        )
    }

    nonisolated private static func releaseGroup() -> MBReleaseGroupSummary {
        MBReleaseGroupSummary(
            id: "group-id",
            title: "Album",
            primaryType: "Album",
            secondaryTypes: nil,
            firstReleaseDate: "2020",
            disambiguation: nil
        )
    }

    nonisolated private static func release(id: String) -> MBRelease {
        MBRelease(
            id: id,
            title: id,
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
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor WikipediaLoaderProbe {
    private(set) var callCount = 0

    func load() throws -> WikipediaSummary {
        callCount += 1
        if callCount == 1 {
            throw URLError(.timedOut)
        }
        return WikipediaSummary(
            title: "Example Artist",
            extract: "Wikipedia summary",
            languageCode: "en",
            pageURL: URL(string: "https://en.wikipedia.org/wiki/Example_Artist")!
        )
    }
}

private actor DiscographyLoaderProbe {
    private(set) var callCount = 0

    func load() -> (groups: [MBReleaseGroupSummary], hasMore: Bool) {
        callCount += 1
        return (
            [
                MBReleaseGroupSummary(
                    id: "group-id",
                    title: "Album",
                    primaryType: "Album",
                    secondaryTypes: nil,
                    firstReleaseDate: "2020",
                    disambiguation: nil
                )
            ],
            false
        )
    }
}
