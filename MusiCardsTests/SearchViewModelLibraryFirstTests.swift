import Combine
import Foundation
import XCTest
@testable import MusiCards

final class SearchViewModelLibraryFirstTests: XCTestCase {
    @MainActor
    func testSharedLibraryCreditOpensTheSearchedCreditedArtistAndVerifiesGroup() async throws {
        let releaseID = "00000000-0000-0000-0000-000000000001"
        let groupID = "00000000-0000-0000-0000-000000000002"
        let steveID = "00000000-0000-0000-0000-000000000003"
        let johnID = "00000000-0000-0000-0000-000000000004"
        let credit = "Steve Khan, John Patitucci, Jack DeJohnette"
        let provider = SearchLibraryProvider(source: .navidrome)
        provider.catalogReleases = [LibraryCatalogRelease(
            releaseID: releaseID,
            title: "The Green Field = El Prado Verde",
            artistName: credit
        )]
        let service = SearchServiceStub()
        service.behaviors["reid:\(releaseID)"] = .results([
            MBReleaseSearchResult(
                id: releaseID,
                title: "The Green Field = El Prado Verde",
                artistCredit: [
                    // Deliberately not in display order: selection uses identity,
                    // never the first name in the library's combined credit.
                    MBArtistCredit(name: "John Patitucci", artist: MBArtist(id: johnID, name: "John Patitucci"), joinPhrase: ", "),
                    MBArtistCredit(name: "Steve Khan", artist: MBArtist(id: steveID, name: "Steve Khan"), joinPhrase: nil)
                ],
                releaseGroup: MBReleaseGroupRef(id: groupID, title: "The Green Field")
            )
        ], 0)
        let manager = LibraryManager(provider: provider, metadataService: service)
        let viewModel = SearchViewModel(
            service: service, libraryManager: manager,
            searchDebounceNanoseconds: 0, coverArtLoader: { _, _ in nil }
        )
        viewModel.searchScope = .libraryOnly
        viewModel.searchQuery = "Steve Khan"
        viewModel.queryDidChange()
        await eventually { viewModel.artistRows.count == 1 && !viewModel.isSearching }
        let steveRow = try XCTUnwrap(viewModel.artistRows.first)
        XCTAssertEqual(steveRow.librarySearchTerm, "Steve Khan")
        let steve = await manager.artistForLibraryCredit(steveRow)
        XCTAssertEqual(steve?.id, steveID)
        XCTAssertTrue(manager.containsReleaseGroup(id: groupID))
        XCTAssertFalse(manager.containsReleaseGroup(id: "different-group"))

        let john = await manager.artistForLibraryCredit(SearchArtistRow(
            id: steveRow.id, name: credit, lifeSpan: "", librarySearchTerm: "John Patitucci"
        ))
        XCTAssertEqual(john?.id, johnID)
        XCTAssertEqual(service.requestedQueries, ["reid:\(releaseID)"])

        let ambiguous = await manager.artistForLibraryCredit(SearchArtistRow(
            id: steveRow.id, name: credit, lifeSpan: "", librarySearchTerm: "a"
        ))
        XCTAssertNil(ambiguous, "An ambiguous query must never pick the first credited artist")
        let absent = await manager.artistForLibraryCredit(SearchArtistRow(
            id: steveRow.id, name: credit, lifeSpan: "", librarySearchTerm: "Chaka Khan"
        ))
        XCTAssertNil(absent, "A name is insufficient unless it occurs in the release's MB credits")

        provider.catalogReleases = []
        XCTAssertFalse(manager.containsReleaseGroup(id: groupID))
    }

    @MainActor
    func testReleaseMetadataFailureCanBeRetriedAndRejectsUnrequestedReleases() async {
        let releaseID = "00000000-0000-0000-0000-000000000001"
        let service = SearchServiceStub()
        let query = "reid:\(releaseID)"
        service.behaviors[query] = .failure(0)
        let provider = SearchLibraryProvider(source: .local)
        provider.catalogReleases = [
            LibraryCatalogRelease(releaseID: releaseID, title: "Album", artistName: "Artist"),
            LibraryCatalogRelease(releaseID: "unrequested-release", title: "Other", artistName: "Other")
        ]
        let manager = LibraryManager(
            provider: provider, metadataService: service
        )
        await manager.prepareReleaseMetadata(for: [releaseID])
        service.behaviors[query] = .results([
            MBReleaseSearchResult(
                id: "unrequested-release", title: "Wrong result",
                releaseGroup: MBReleaseGroupRef(id: "wrong-group", title: nil)
            )
        ], 0)
        await manager.prepareReleaseMetadata(for: [releaseID])
        XCTAssertEqual(service.requestedQueries.count, 2)
        XCTAssertFalse(manager.containsReleaseGroup(id: "wrong-group"))
        service.behaviors[query] = .results([
            MBReleaseSearchResult(
                id: releaseID, title: "Album",
                releaseGroup: MBReleaseGroupRef(id: "correct-group", title: nil)
            )
        ], 0)
        await manager.prepareReleaseMetadata(for: [releaseID])
        XCTAssertTrue(manager.containsReleaseGroup(id: "correct-group"))
        await manager.prepareReleaseMetadata(for: [releaseID])
        XCTAssertEqual(service.requestedQueries.count, 3, "Only successful metadata is cached")
    }

    @MainActor
    func testCancelledMetadataResponseDoesNotPublishMembership() async {
        let releaseID = "00000000-0000-0000-0000-000000000001"
        let service = SearchServiceStub()
        service.behaviors["reid:\(releaseID)"] = .results([
            MBReleaseSearchResult(
                id: releaseID, title: "Album",
                releaseGroup: MBReleaseGroupRef(id: "group", title: nil)
            )
        ], 30_000_000)
        let provider = SearchLibraryProvider(source: .local)
        provider.catalogReleases = [LibraryCatalogRelease(
            releaseID: releaseID, title: "Album", artistName: "Artist"
        )]
        let manager = LibraryManager(provider: provider, metadataService: service)
        let task = Task { await manager.prepareReleaseMetadata(for: [releaseID]) }
        await eventually { !service.requestedQueries.isEmpty }
        task.cancel()
        await task.value
        XCTAssertFalse(manager.containsReleaseGroup(id: "group"))
    }

    @MainActor
    func testSearchResultDecodesReleaseGroupAndOldArtistRowsRemainReadable() throws {
        let release = try JSONDecoder().decode(MBReleaseSearchResult.self, from: Data(
            #"{"id":"release","title":"Edition title","release-group":{"id":"group","title":"Album title"}}"#.utf8
        ))
        XCTAssertEqual(release.releaseGroup?.id, "group")
        let oldRow = try JSONDecoder().decode(SearchArtistRow.self, from: Data(
            #"{"id":"artist","name":"Steve Khan","lifeSpan":"1947–"}"#.utf8
        ))
        XCTAssertNil(oldRow.librarySearchTerm)
    }

    func testLibraryCatalogQueryMakesCommaSyntaxExplicit() {
        XCTAssertEqual(
            SearchViewModel.libraryCatalogQuery(from: "Miles Davis"),
            .artists(matching: "Miles Davis")
        )
        XCTAssertEqual(
            SearchViewModel.libraryCatalogQuery(from: "Miles Davis,"),
            .releases(artist: "Miles Davis", text: nil)
        )
        XCTAssertEqual(
            SearchViewModel.libraryCatalogQuery(
                from: "Miles Davis, Kind of Blue"
            ),
            .releases(artist: "Miles Davis", text: "Kind of Blue")
        )
        XCTAssertEqual(
            SearchViewModel.libraryCatalogQuery(from: ", Kind of Blue"),
            .releases(artist: nil, text: "Kind of Blue")
        )
    }

    @MainActor
    func testLibraryOnlyReleaseSearchDoesNotCallMusicBrainz() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)
        viewModel.searchScope = .libraryOnly

        viewModel.searchQuery = "Nirvana, Nevermind"
        viewModel.queryDidChange()
        await eventually { !viewModel.isSearching }

        XCTAssertTrue(service.requestedQueries.isEmpty)
        XCTAssertTrue(viewModel.releaseResults.isEmpty)
    }

    @MainActor
    func testLibraryOnlyArtistSearchDoesNotCallMusicBrainz() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)
        viewModel.searchScope = .libraryOnly

        viewModel.searchQuery = "Nirvana"
        viewModel.queryDidChange()
        await eventually { !viewModel.isSearching }

        XCTAssertTrue(service.requestedArtistQueries.isEmpty)
        XCTAssertTrue(viewModel.artistRows.isEmpty)
    }

    @MainActor
    func testBarcodeRetryRepeatsTheSameBarcodeRequest() async {
        let service = SearchServiceStub()
        service.behaviors["barcode:0123456789012"] = .failure(0)
        let viewModel = makeViewModel(service: service)

        viewModel.searchByBarcode("0 123456 789012")
        await eventually { viewModel.searchError != nil }

        viewModel.retrySearch()
        await eventually { service.requestedQueries.count == 2 }

        XCTAssertEqual(
            service.requestedQueries,
            ["barcode:0123456789012", "barcode:0123456789012"]
        )
    }

    @MainActor
    func testBarcodeSearchDoesNotAdvertisePagination() async {
        let service = SearchServiceStub()
        service.behaviors["barcode:0123456789012"] = .results(
            (0..<20).map {
                MBReleaseSearchResult(
                    id: "barcode-release-\($0)",
                    title: "Barcode Release \($0)"
                )
            },
            0
        )
        let viewModel = makeViewModel(service: service)

        viewModel.searchByBarcode("0123456789012")
        await eventually { !viewModel.isSearching }

        XCTAssertEqual(viewModel.releaseResults.count, 20)
        XCTAssertFalse(viewModel.hasMoreResults)
    }

    @MainActor
    func testRecognizedTrackRetryRepeatsRecordingResolution() async {
        let service = SearchServiceStub()
        service.recordingBehavior = .error(SearchTestError.failed, 0)
        let viewModel = makeViewModel(service: service)

        viewModel.searchByRecognizedTrack(
            artist: "Miles Davis",
            title: "So What"
        )
        await eventually { viewModel.searchError != nil }

        viewModel.retrySearch()
        await eventually { service.requestedRecordingQueries.count == 2 }

        XCTAssertEqual(
            service.requestedRecordingQueries,
            ["Miles Davis|So What", "Miles Davis|So What"]
        )
        XCTAssertTrue(service.requestedQueries.isEmpty)
    }

    @MainActor
    func testRecognizedTrackRetryKeepsItsOriginAfterReleaseGroupFailure() async {
        let service = SearchServiceStub()
        let candidate = MBReleaseSearchResult(
            id: "release-a",
            title: "Kind of Blue",
            artistCredit: [
                MBArtistCredit(
                    name: "Miles Davis",
                    artist: nil,
                    joinPhrase: nil
                )
            ]
        )
        service.recordingBehavior = .results([
            MBRecordingSearchResult(
                id: "recording-a",
                title: "So What",
                artistCredit: candidate.artistCredit,
                releases: [candidate]
            )
        ], 0)
        service.loadedReleases["release-a"] = MBRelease(
            id: "release-a",
            title: "Kind of Blue",
            artistCredit: candidate.artistCredit,
            date: nil,
            country: nil,
            barcode: nil,
            disambiguation: nil,
            labelInfo: nil,
            media: [
                MBMedium(
                    position: 1,
                    trackCount: 1,
                    format: "CD",
                    tracks: [MBTrack(title: "So What")]
                )
            ],
            releaseGroup: MBReleaseGroupRef(
                id: "group-a",
                title: "Kind of Blue"
            ),
            relations: nil,
            annotation: nil
        )
        service.releaseGroupPages["group-a"] = [
            0: .error(SearchTestError.failed, 0)
        ]
        let viewModel = makeViewModel(service: service)

        viewModel.searchByRecognizedTrack(
            artist: "Miles Davis",
            title: "So What"
        )
        await eventually { viewModel.searchError != nil }

        viewModel.retrySearch()
        await eventually { service.requestedReleaseGroupIDs.count == 2 }

        XCTAssertEqual(
            service.requestedRecordingQueries,
            ["Miles Davis|So What", "Miles Davis|So What"]
        )
    }

    @MainActor
    func testRecognizedTrackClearsPreviousReleaseMergeState() async {
        let provider = SearchLibraryProvider(source: .local)
        provider.catalogReleases = [
            LibraryCatalogRelease(
                releaseID: "owned-release",
                title: "So What",
                artistName: "Miles Davis"
            )
        ]
        let service = SearchServiceStub()
        let viewModel = SearchViewModel(
            service: service,
            libraryManager: LibraryManager(provider: provider),
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
        )

        viewModel.searchQuery = "Miles Davis, So What"
        viewModel.queryDidChange()
        await eventually {
            viewModel.releaseResults.map(\.id) == ["owned-release"]
        }

        viewModel.searchByRecognizedTrack(
            artist: "Miles Davis",
            title: "So What"
        )
        await eventually { !viewModel.isSearching }
        XCTAssertTrue(viewModel.releaseResults.isEmpty)

        provider.availabilitySubject.send()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(viewModel.releaseResults.isEmpty)
    }

    @MainActor
    func testRecognizedTrackWithSameQueryDoesNotSuppressNextUserSearch() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "Miles Davis, So What"
        viewModel.queryDidChange()
        await eventually { !viewModel.isSearching }

        viewModel.searchByRecognizedTrack(
            artist: "Miles Davis",
            title: "So What"
        )
        await eventually { !viewModel.isSearching }

        viewModel.searchQuery = "John Coltrane"
        viewModel.queryDidChange()
        await eventually {
            service.requestedArtistQueries.contains("John Coltrane")
        }
    }

    @MainActor
    func testRecognizedTrackDoesNotSuppressUserEditBeforeViewChangeCallback() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "Previous artist"
        viewModel.queryDidChange()
        await eventually { !viewModel.isSearching }

        viewModel.searchByRecognizedTrack(
            artist: "Miles Davis",
            title: "So What"
        )
        // The search card may not yet be mounted to deliver its onChange.
        viewModel.searchQuery = "John Coltrane"
        viewModel.queryDidChange()

        await eventually {
            service.requestedArtistQueries.contains("John Coltrane")
        }
    }

    @MainActor
    func testRecognizedTrackViewChangeDoesNotStartTextSearch() async {
        let service = SearchServiceStub()
        let viewModel = makeViewModel(service: service)

        viewModel.searchByRecognizedTrack(
            artist: "Miles Davis",
            title: "So What"
        )
        viewModel.queryDidChange()
        await eventually { !viewModel.isSearching }

        XCTAssertTrue(service.requestedQueries.isEmpty)
        XCTAssertTrue(service.requestedArtistQueries.isEmpty)
    }

    func testSearchCardLabelFollowsExistingSearchMode() {
        XCTAssertEqual(SearchMode.search.cardLabel, "Search")
        XCTAssertEqual(
            SearchMode.releaseGroupResults(releaseGroupID: "rgid").cardLabel,
            "Release Versions"
        )
    }

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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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
    func testStaleReleaseGroupFailureCannotReplaceNewerGroup() async {
        let service = SearchServiceStub()
        service.releaseGroupPages["group-a"] = [
            0: .error(SearchTestError.failed, 150_000_000)
        ]
        service.releaseGroupPages["group-b"] = [
            0: .page([], hasMore: false, delay: 0)
        ]
        let viewModel = makeViewModel(service: service)

        viewModel.loadReleaseGroupResults(
            releaseGroupID: "group-a",
            releaseTitle: "Group A",
            artistName: "Artist"
        )
        await eventually { service.requestedReleaseGroupIDs.contains("group-a") }

        viewModel.loadReleaseGroupResults(
            releaseGroupID: "group-b",
            releaseTitle: "Group B",
            artistName: "Artist"
        )
        await eventually { !viewModel.isSearching }
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(
            viewModel.mode,
            .releaseGroupResults(releaseGroupID: "group-b")
        )
        XCTAssertTrue(viewModel.releaseResults.isEmpty)
        XCTAssertNil(viewModel.searchError)
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
        )

        viewModel.searchQuery = "Nirvana"
        viewModel.queryDidChange()

        await eventually { service.requestedArtistQueries == ["Nirvana"] }
        await eventually { !viewModel.isSearching }
        XCTAssertTrue(viewModel.releaseResults.isEmpty)
    }

    @MainActor
    func testStaleArtistPageCannotAppendIntoNewerSearch() async {
        let service = SearchServiceStub()
        service.artistPages["alpha"] = [
            0: .results(artistResults(prefix: "alpha", count: 20), 0),
            20: .results(artistResults(prefix: "stale", count: 20), 150_000_000)
        ]
        service.artistPages["beta"] = [
            0: .results([MBArtistSearchResult(id: "beta", name: "Beta", lifeSpan: nil)], 0)
        ]
        let viewModel = makeViewModel(service: service)

        viewModel.searchQuery = "alpha"
        viewModel.queryDidChange()
        await eventually { viewModel.artistRows.count == 20 }

        viewModel.loadMoreIfNeededForArtist(
            currentItem: viewModel.artistRows[19]
        )
        await eventually { service.requestedArtistOffsets.contains(20) }

        viewModel.searchQuery = "beta"
        viewModel.queryDidChange()
        await eventually { viewModel.artistRows.map(\.id) == ["beta"] }
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(viewModel.artistRows.map(\.id), ["beta"])
        XCTAssertFalse(viewModel.isLoadingMore)
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
            searchDebounceNanoseconds: 0,
            coverArtLoader: { _, _ in nil }
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

    private func artistResults(
        prefix: String,
        count: Int
    ) -> [MBArtistSearchResult] {
        (0..<count).map {
            MBArtistSearchResult(
                id: "\(prefix)-\($0)",
                name: "\(prefix) \($0)",
                lifeSpan: nil
            )
        }
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
    func searchCatalog(
        query: LibraryCatalogQuery,
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

    enum ArtistBehavior {
        case results([MBArtistSearchResult], UInt64)
        case error(Error, UInt64)
    }

    enum ReleaseGroupBehavior {
        case page([MBReleaseSearchResult], hasMore: Bool, delay: UInt64)
        case error(Error, UInt64)
    }

    enum RecordingBehavior {
        case results([MBRecordingSearchResult], UInt64)
        case error(Error, UInt64)
    }

    var behaviors: [String: Behavior] = [:]
    var releasePages: [String: [Int: [MBReleaseSearchResult]]] = [:]
    var artistPages: [String: [Int: ArtistBehavior]] = [:]
    var releaseGroupPages: [String: [Int: ReleaseGroupBehavior]] = [:]
    var recordingBehavior: RecordingBehavior = .results([], 0)
    var loadedReleases: [String: MBRelease] = [:]
    private(set) var requestedQueries: [String] = []
    private(set) var requestedReleaseOffsets: [Int] = []
    private(set) var completedReleaseQueries: [String] = []
    private(set) var requestedArtistQueries: [String] = []
    private(set) var requestedArtistOffsets: [Int] = []
    private(set) var requestedReleaseGroupIDs: [String] = []
    private(set) var requestedRecordingQueries: [String] = []

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
        requestedArtistOffsets.append(offset)
        guard let behavior = artistPages[query]?[offset] else { return [] }
        switch behavior {
        case .results(let results, let delay):
            try? await Task.sleep(nanoseconds: delay)
            return results
        case .error(let error, let delay):
            try? await Task.sleep(nanoseconds: delay)
            throw error
        }
    }

    func fetchReleasesForReleaseGroup(
        id: String,
        limit: Int,
        offset: Int
    ) async throws -> (releases: [MBReleaseSearchResult], hasMore: Bool) {
        requestedReleaseGroupIDs.append(id)
        guard let behavior = releaseGroupPages[id]?[offset] else {
            return ([], false)
        }
        switch behavior {
        case .page(let releases, let hasMore, let delay):
            try? await Task.sleep(nanoseconds: delay)
            return (releases, hasMore)
        case .error(let error, let delay):
            try? await Task.sleep(nanoseconds: delay)
            throw error
        }
    }

    func searchRecordings(
        trackTitle: String,
        artistName: String?,
        limit: Int,
        offset: Int
    ) async throws -> [MBRecordingSearchResult] {
        requestedRecordingQueries.append("\(artistName ?? "")|\(trackTitle)")
        switch recordingBehavior {
        case .results(let results, let delay):
            try? await Task.sleep(nanoseconds: delay)
            return results
        case .error(let error, let delay):
            try? await Task.sleep(nanoseconds: delay)
            throw error
        }
    }

    func loadRelease(id: String) async throws -> MBRelease {
        if let release = loadedReleases[id] {
            return release
        }
        throw SearchTestError.failed
    }
}

private enum SearchTestError: Error {
    case failed
}
