import XCTest
@testable import MusiCards

final class ReleaseSelectionRaceTests: XCTestCase {
    @MainActor
    func testLatestReleaseSelectionWinsWhenOlderSuccessFinishesLast() async {
        let model = makeModel { id in
            if id == "A" {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return Self.release(id: id)
        }

        model.selectRelease(row(id: "A"))
        model.selectRelease(row(id: "B"))

        await eventually {
            model.selectedRelease?.id == "B" && !model.isLoadingRelease
        }
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(model.selectedReleaseID, "B")
        XCTAssertEqual(model.selectedRelease?.id, "B")
        XCTAssertNil(model.releaseError)
    }

    @MainActor
    func testOlderReleaseFailureCannotClearNewerSuccess() async {
        let model = makeModel { id in
            if id == "A" {
                try? await Task.sleep(nanoseconds: 150_000_000)
                throw ReleaseLoadTestError.failed
            }
            return Self.release(id: id)
        }

        model.selectRelease(row(id: "A"))
        model.selectRelease(row(id: "B"))

        await eventually {
            model.selectedRelease?.id == "B" && !model.isLoadingRelease
        }
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(model.selectedReleaseID, "B")
        XCTAssertEqual(model.selectedRelease?.id, "B")
        XCTAssertNil(model.releaseError)
    }

    @MainActor
    func testAdoptedPlaybackPreloadsCardsWithoutLeavingPlayer() async {
        let model = MusiCardsAppModel(
            playbackEngine: PendingPlaybackEngine(),
            releaseDetailLoader: { id in
                Self.release(id: id)
            },
            releaseCoverLoader: { _ in nil },
            artistDetailLoader: { _ in throw ReleaseLoadTestError.failed },
            artistReleaseGroupsLoader: { _, _, _ in ([], false) },
            artistWikipediaLoader: { _ in nil }
        )
        model.deckSelection = DeckSelection<MusiCardID>(
            activeID: .player,
            activeSlotIndex: MusiCardID.player.slotIndex
        )
        let track = PlaybackTrack(
            id: "song-1",
            releaseTrackID: nil,
            recordingID: "recording-1",
            releaseID: "release-1",
            title: "Song",
            artist: "Artist",
            albumTitle: "Release",
            duration: 180,
            artworkData: nil
        )
        let queue = ReleasePlaybackQueue(
            items: [
                PlaybackQueueItem(
                    track: track,
                    source: .localFile(URL(fileURLWithPath: "/tmp/song.flac"))
                )
            ],
            selectedIndex: 0
        )

        await model.preloadPlaybackContext(from: queue)

        XCTAssertEqual(model.deckSelection.activeID, .player)
        XCTAssertEqual(model.selectedRelease?.id, "release-1")
        XCTAssertNil(model.selectedArtistID)
        XCTAssertFalse(model.isBlockingNavigationLoad)
    }

    @MainActor
    func testUnambiguousArtistRejectsCollaborationsAndVariousArtists() {
        let solo = MBArtist(id: "solo", name: "Solo")
        let soloRelease = release(
            id: "solo-release",
            artistCredit: [
                MBArtistCredit(name: "Solo", artist: solo, joinPhrase: "")
            ]
        )
        XCTAssertEqual(
            MusiCardsAppModel.unambiguousArtist(in: soloRelease)?.id,
            "solo"
        )

        let collaboration = release(
            id: "collaboration",
            artistCredit: [
                MBArtistCredit(name: "One", artist: solo, joinPhrase: " & "),
                MBArtistCredit(
                    name: "Two",
                    artist: MBArtist(id: "two", name: "Two"),
                    joinPhrase: ""
                )
            ]
        )
        XCTAssertNil(MusiCardsAppModel.unambiguousArtist(in: collaboration))

        let various = MBArtist(
            id: "89ad4ac3-39f7-470e-963a-56509c546377",
            name: "Various Artists"
        )
        XCTAssertNil(
            MusiCardsAppModel.unambiguousArtist(
                in: release(
                    id: "various",
                    artistCredit: [
                        MBArtistCredit(
                            name: "Various Artists",
                            artist: various,
                            joinPhrase: ""
                        )
                    ]
                )
            )
        )
    }

    @MainActor
    private func makeModel(
        loader: @escaping @Sendable (String) async throws -> MBRelease
    ) -> MusiCardsAppModel {
        MusiCardsAppModel(
            playbackEngine: PendingPlaybackEngine(),
            releaseDetailLoader: loader,
            releaseCoverLoader: { _ in nil }
        )
    }

    private func row(id: String) -> SearchReleaseRow {
        SearchReleaseRow(
            id: id,
            title: "Release \(id)",
            artistLine: "Artist",
            metaLine: "",
            disambiguation: "",
            hasCoverArt: false
        )
    }

    nonisolated private static func release(id: String) -> MBRelease {
        MBRelease(
            id: id,
            title: "Release \(id)",
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

    @MainActor
    private func release(
        id: String,
        artistCredit: [MBArtistCredit]
    ) -> MBRelease {
        MBRelease(
            id: id,
            title: "Release \(id)",
            artistCredit: artistCredit,
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

private enum ReleaseLoadTestError: Error {
    case failed
}
