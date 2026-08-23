import Combine
import Foundation
import XCTest
@testable import MusiCards

final class SearchViewModelLibraryFirstTests: XCTestCase {
    @MainActor
    func testTrailingSpaceDoesNotRestartEquivalentArtistSearch() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "miles"
        viewModel.queryDidChange()
        await eventually { service.requestedArtistQueries == ["miles"] }

        viewModel.searchQuery = "miles "
        viewModel.queryDidChange()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(service.requestedArtistQueries, ["miles"])
    }

    @MainActor
    func testTrailingSpaceDoesNotRestartEquivalentReleaseSearch() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "miles davis,"
        viewModel.queryDidChange()
        await eventually { service.requestedQueries == ["miles davis,"] }

        viewModel.searchQuery = "miles davis, "
        viewModel.queryDidChange()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(service.requestedQueries, ["miles davis,"])
    }

    @MainActor
    func testBackspacingEquivalentTrailingSpaceDoesNotRestartReleaseSearch() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "miles davis, "
        viewModel.queryDidChange()
        await eventually { service.requestedQueries == ["miles davis,"] }

        viewModel.searchQuery = "miles davis,"
        viewModel.queryDidChange()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(service.requestedQueries, ["miles davis,"])
    }

    @MainActor
    func testMeaningfulReleaseFragmentStartsNewSearch() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "miles davis,"
        viewModel.queryDidChange()
        await eventually { service.requestedQueries.count == 1 }

        viewModel.searchQuery = "miles davis, k"
        viewModel.queryDidChange()
        await eventually { service.requestedQueries.count == 2 }

        XCTAssertEqual(service.requestedQueries, ["miles davis,", "miles davis, k"])
    }

    @MainActor
    func testCommaModeChangeStartsReleaseSearch() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "miles davis"
        viewModel.queryDidChange()
        await eventually { service.requestedArtistQueries == ["miles davis"] }

        viewModel.searchQuery = "miles davis,"
        viewModel.queryDidChange()
        await eventually { service.requestedQueries == ["miles davis,"] }
    }

    @MainActor
    func testRetryRepeatsSameNormalizedQueryAfterFailure() async {
        let service = SearchServiceStub()
        service.behaviors["miles davis,"] = .failure(0)
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "miles davis, "
        viewModel.queryDidChange()
        await eventually { viewModel.searchError != nil }

        viewModel.retrySearch()
        await eventually {
            service.requestedQueries.count == 2 && viewModel.searchError != nil
        }

        XCTAssertEqual(service.requestedQueries, ["miles davis,", "miles davis,"])
    }

    @MainActor
    func testCancellationErrorDoesNotPublishSearchError() async {
        let service = SearchServiceStub()
        service.behaviors["miles davis,"] = .error(CancellationError(), 0)
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "miles davis,"
        viewModel.queryDidChange()
        await eventually { !viewModel.isSearching }

        XCTAssertNil(viewModel.searchError)
    }

    @MainActor
    func testURLCancellationDoesNotPublishConnectivityError() async {
        let service = SearchServiceStub()
        service.behaviors["miles davis,"] = .error(URLError(.cancelled), 0)
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "miles davis,"
        viewModel.queryDidChange()
        await eventually { !viewModel.isSearching }

        XCTAssertNil(viewModel.searchError)
    }

    @MainActor
    func testMergeKeepsLibraryOrderDeduplicatesAndEnrichesExactMBID() {
        let ownedA = row(id: "A", title: "Owned A")
        let ownedB = row(id: "B", title: "Owned B")
        let enrichedB = row(
            id: "b",
            title: "MusicBrainz B",
            artist: "Enriched Artist",
            metadata: "1991 · US"
        )
        let globalC = row(id: "C", title: "Global C")

        let merged = SearchViewModel.mergeLibraryFirst(
            libraryRows: [ownedA, ownedB],
            musicBrainzRows: [globalC, enrichedB, globalC]
        )

        XCTAssertEqual(merged.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(merged[1].title, "MusicBrainz B")
        XCTAssertEqual(merged[1].artistLine, "Enriched Artist")
        XCTAssertEqual(merged[1].metaLine, "1991 · US")
    }

    @MainActor
    func testLibraryResultSurvivesMusicBrainzFailure() async {
        let provider = SearchLibraryProvider(source: .local)
        provider.catalogReleases = [nevermindRelease]
        let service = SearchServiceStub()
        service.behaviors["Nirvana, Nevermind"] = .failure(80_000_000)
        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0
        )

        viewModel.searchQuery = "Nirvana, Nevermind"
        viewModel.queryDidChange()

        await eventually {
            viewModel.releaseResults.map(\.id) == [self.nevermindRelease.releaseID]
                && !viewModel.isSearching
        }
        XCTAssertFalse(
            service.completedReleaseQueries.contains("Nirvana, Nevermind")
        )
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(
            viewModel.releaseResults.map(\.id),
            [nevermindRelease.releaseID]
        )
        XCTAssertNil(viewModel.searchError)
    }

    @MainActor
    func testReleaseVersionPromotesOwnedExactReleaseOutsideFirstPage() async {
        let provider = SearchLibraryProvider(source: .local)
        provider.catalogReleases = [nevermindRelease]
        let service = SearchServiceStub()
        let releaseGroupID = "11111111-1111-1111-1111-111111111111"
        let validationQuery = "rgid:\(releaseGroupID) AND (reid:\(nevermindRelease.releaseID))"
        service.behaviors[validationQuery] = .results([
            MBReleaseSearchResult(id: nevermindRelease.releaseID, title: "Nevermind")
        ], 0)

        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0
        )
        viewModel.loadReleaseGroupResults(
            releaseGroupID: releaseGroupID,
            releaseTitle: "Nevermind",
            artistName: "Nirvana"
        )

        await eventually {
            viewModel.releaseResults.map(\.id) == [self.nevermindRelease.releaseID]
                && !viewModel.isSearching
        }
        XCTAssertEqual(service.requestedQueries, [validationQuery])
        XCTAssertEqual(viewModel.releaseResults.first?.id, nevermindRelease.releaseID)
    }

    @MainActor
    func testReleaseVersionRejectsFalseLibraryCandidate() async {
        let provider = SearchLibraryProvider(source: .local)
        provider.catalogReleases = [nevermindRelease]
        let service = SearchServiceStub()
        let releaseGroupID = "22222222-2222-2222-2222-222222222222"
        let validationQuery = "rgid:\(releaseGroupID) AND (reid:\(nevermindRelease.releaseID))"
        service.behaviors[validationQuery] = .empty(0)

        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0
        )
        viewModel.loadReleaseGroupResults(
            releaseGroupID: releaseGroupID,
            releaseTitle: "Nevermind",
            artistName: "Nirvana"
        )

        await eventually { !viewModel.isSearching }
        XCTAssertTrue(viewModel.releaseResults.isEmpty)
        XCTAssertEqual(service.requestedQueries, [validationQuery])
    }

    @MainActor
    func testMusicBrainzResultsAppendWithoutWaitingForCoverArt() async {
        let provider = SearchLibraryProvider(source: .navidrome)
        provider.catalogReleases = [nevermindRelease]
        let service = SearchServiceStub()
        service.behaviors["Nirvana, Nevermind"] = .results(
            [
                MBReleaseSearchResult(
                    id: nevermindRelease.releaseID,
                    title: "Nevermind (MusicBrainz enriched)"
                ),
                MBReleaseSearchResult(
                    id: "6e1d48f7-717c-416e-af35-5d2454a13af2",
                    title: "Another Nevermind Release"
                )
            ],
            80_000_000
        )
        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0
        )

        viewModel.searchQuery = "Nirvana, Nevermind"
        viewModel.queryDidChange()
        await eventually {
            viewModel.releaseResults.map(\.id) == [self.nevermindRelease.releaseID]
        }
        XCTAssertFalse(
            service.completedReleaseQueries.contains("Nirvana, Nevermind")
        )
        XCTAssertTrue(viewModel.isLoadingMore)

        await eventually { viewModel.releaseResults.count == 2 }

        XCTAssertEqual(
            viewModel.releaseResults.map(\.id),
            [
                nevermindRelease.releaseID,
                "6e1d48f7-717c-416e-af35-5d2454a13af2"
            ]
        )
        XCTAssertEqual(
            viewModel.releaseResults.first?.title,
            "Nevermind (MusicBrainz enriched)"
        )
        XCTAssertTrue(viewModel.releaseResults.allSatisfy(\.hasCoverArt))
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    @MainActor
    func testReleaseResultsShowTwentyAndRequestNextPageOnlyAtBottom() async {
        let provider = SearchLibraryProvider(source: .navidrome)
        provider.catalogReleases = [nevermindRelease]
        let service = SearchServiceStub()
        service.releasePages["Nirvana, Nevermind"] = [
            0: (0..<20).map {
                MBReleaseSearchResult(
                    id: "global-release-\($0)",
                    title: "Global Release \($0)"
                )
            },
            20: (20..<40).map {
                MBReleaseSearchResult(
                    id: "global-release-\($0)",
                    title: "Global Release \($0)"
                )
            }
        ]
        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0
        )

        viewModel.searchQuery = "Nirvana, Nevermind"
        viewModel.queryDidChange()

        await eventually {
            viewModel.releaseResults.count == 20
                && !viewModel.isLoadingMore
        }
        XCTAssertEqual(viewModel.releaseResults.first?.id, nevermindRelease.releaseID)
        XCTAssertEqual(service.requestedReleaseOffsets, [0])

        viewModel.loadMoreIfNeededForRelease(
            currentItem: viewModel.releaseResults[18]
        )
        await Task.yield()
        XCTAssertEqual(service.requestedReleaseOffsets, [0])

        viewModel.loadMoreIfNeededForRelease(
            currentItem: viewModel.releaseResults[19]
        )
        await eventually {
            viewModel.releaseResults.count == 40
                && service.requestedReleaseOffsets == [0, 20]
                && !viewModel.isLoadingMore
        }
    }

    @MainActor
    func testCatalogBecomingReadyUpdatesExistingQuery() async {
        let provider = SearchLibraryProvider(source: .navidrome)
        let service = SearchServiceStub()
        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0
        )
        viewModel.searchQuery = "Nirvana, Nevermind"
        viewModel.queryDidChange()
        await eventually { !viewModel.isSearching }
        XCTAssertTrue(viewModel.releaseResults.isEmpty)

        provider.catalogReleases = [nevermindRelease]
        provider.availabilitySubject.send()

        await eventually {
            viewModel.releaseResults.map(\.id) == [self.nevermindRelease.releaseID]
        }
    }

    @MainActor
    func testSourceSwitchReplacesOwnedResultsForCurrentQuery() async {
        let local = SearchLibraryProvider(source: .local)
        local.catalogReleases = [
            LibraryCatalogRelease(
                releaseID: "local-release",
                title: "Shared Album",
                artistName: "Shared Artist"
            )
        ]
        let navidrome = SearchLibraryProvider(source: .navidrome)
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
        let viewModel = SearchViewModel(
            service: SearchServiceStub(),
            libraryManager: manager,
            searchDebounceNanoseconds: 0
        )
        viewModel.searchQuery = "Shared Artist, Shared Album"
        viewModel.queryDidChange()
        await eventually { viewModel.releaseResults.map(\.id) == ["local-release"] }

        manager.setActiveSource(.navidrome)

        await eventually {
            viewModel.releaseResults.map(\.id) == ["navidrome-release"]
        }
    }

    @MainActor
    func testStaleFailureCannotReplaceNewerLibraryResults() async {
        let provider = SearchLibraryProvider(source: .local)
        provider.catalogReleases = [
            LibraryCatalogRelease(
                releaseID: "first",
                title: "First",
                artistName: "Artist"
            ),
            LibraryCatalogRelease(
                releaseID: "second",
                title: "Second",
                artistName: "Artist"
            )
        ]
        let service = SearchServiceStub()
        service.behaviors["Artist, First"] = .failure(150_000_000)
        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0
        )

        viewModel.searchQuery = "Artist, First"
        viewModel.queryDidChange()
        await eventually { service.requestedQueries.contains("Artist, First") }

        viewModel.searchQuery = "Artist, Second"
        viewModel.queryDidChange()
        await eventually { viewModel.releaseResults.map(\.id) == ["second"] }
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(viewModel.releaseResults.map(\.id), ["second"])
        XCTAssertNil(viewModel.searchError)
    }

    @MainActor
    func testArtistSearchModeDoesNotPublishLibraryReleaseRows() async {
        let provider = SearchLibraryProvider(source: .local)
        provider.catalogReleases = [nevermindRelease]
        let service = SearchServiceStub()
        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0
        )

        viewModel.searchQuery = "Nirvana"
        viewModel.queryDidChange()

        await eventually { service.requestedArtistQueries == ["Nirvana"] }
        await eventually { !viewModel.isSearching }
        XCTAssertTrue(viewModel.releaseResults.isEmpty)
    }

    private var nevermindRelease: LibraryCatalogRelease {
        LibraryCatalogRelease(
            releaseID: "189002e7-3285-4e2e-92a3-7f6c30d407a2",
            title: "Nevermind",
            artistName: "Nirvana",
            format: "FLAC",
            trackTitles: ["Smells Like Teen Spirit"]
        )
    }

    @MainActor
    private func makeViewModel(service: SearchServiceStub) -> SearchViewModel {
        SearchViewModel(
            service: service,
            libraryManager: LibraryManager(
                provider: SearchLibraryProvider(source: .local)
            ),
            searchDebounceNanoseconds: 0
        )
    }

    private func row(
        id: String,
        title: String,
        artist: String = "Artist",
        metadata: String = ""
    ) -> SearchReleaseRow {
        SearchReleaseRow(
            id: id,
            title: title,
            artistLine: artist,
            metaLine: metadata,
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

@MainActor
private final class SearchLibraryProvider: LibraryProvider {
    let source: LibrarySource
    var catalogState: LibraryCatalogState = .ready
    var catalogSummary = LibraryCatalogSummary()
    let availabilitySubject = PassthroughSubject<Void, Never>()
    var catalogReleases: [LibraryCatalogRelease] = []

    init(source: LibrarySource) {
        self.source = source
    }

    var availabilityChanges: AnyPublisher<Void, Never> {
        availabilitySubject.eraseToAnyPublisher()
    }

    func refreshCatalog() async {}
    func searchCatalog(query: String, limit: Int) -> [LibraryCatalogRelease] {
        LibraryCatalogSearch.search(
            catalogReleases,
            query: query,
            limit: limit
        )
    }
    func prepareTrackAvailability(forRelease releaseID: String) async {}
    func containsRelease(_ releaseID: String) -> Bool {
        catalogReleases.contains { $0.releaseID == releaseID }
    }
    func containsArtist(named artistName: String) -> Bool { false }
    func containsReleaseGroup(title: String, artistName: String) -> Bool { false }
    func containsTrack(_ identity: LibraryTrackIdentity) -> Bool { false }
    func playableTrack(for identity: LibraryTrackIdentity) -> LibraryPlayableTrack? {
        nil
    }
    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource {
        throw PlaybackAssetResolutionError.assetUnavailable
    }
}

@MainActor
private final class SearchServiceStub: MusicBrainzSearchServing {
    enum Behavior {
        case empty(UInt64)
        case failure(UInt64)
        case results([MBReleaseSearchResult], UInt64)
        case error(Error, UInt64)
    }

    var behaviors: [String: Behavior] = [:]
    var releasePages: [String: [Int: [MBReleaseSearchResult]]] = [:]
    private(set) var requestedQueries: [String] = []
    private(set) var requestedReleaseOffsets: [Int] = []
    private(set) var completedReleaseQueries: [String] = []
    private(set) var requestedArtistQueries: [String] = []

    func searchReleases(
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> [MBReleaseSearchResult] {
        requestedQueries.append(query)
        requestedReleaseOffsets.append(offset)
        if let page = releasePages[query]?[offset] {
            completedReleaseQueries.append(query)
            return page
        }
        let behavior = behaviors[query] ?? .empty(0)
        switch behavior {
        case .empty(let delay):
            try? await Task.sleep(nanoseconds: delay)
            completedReleaseQueries.append(query)
            return []
        case .failure(let delay):
            try? await Task.sleep(nanoseconds: delay)
            completedReleaseQueries.append(query)
            throw SearchTestError.failed
        case .results(let results, let delay):
            try? await Task.sleep(nanoseconds: delay)
            completedReleaseQueries.append(query)
            return results
        case .error(let error, let delay):
            try? await Task.sleep(nanoseconds: delay)
            completedReleaseQueries.append(query)
            throw error
        }
    }

    func searchArtists(
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> [MBArtistSearchResult] {
        requestedArtistQueries.append(query)
        return []
    }

    func fetchReleasesForReleaseGroup(
        id: String,
        limit: Int,
        offset: Int
    ) async throws -> (releases: [MBReleaseSearchResult], hasMore: Bool) {
        ([], false)
    }

    func searchRecordings(
        trackTitle: String,
        artistName: String?,
        limit: Int,
        offset: Int
    ) async throws -> [MBRecordingSearchResult] {
        []
    }

    func loadRelease(id: String) async throws -> MBRelease {
        throw SearchTestError.failed
    }
}

private enum SearchTestError: Error {
    case failed
}
