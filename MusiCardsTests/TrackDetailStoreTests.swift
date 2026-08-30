import XCTest
@testable import MusiCards

@MainActor
final class TrackDetailStoreTests: XCTestCase {
    func testWorkFailurePreservesRecordingLevelDetails() async {
        let service = ScriptedTrackDetailService(
            recording: Self.recording,
            workResults: [.failure(MusicBrainzServiceError.httpFailure(statusCode: 404))]
        )
        let store = TrackDetailStore(service: service)

        store.fetchIfNeeded(recordingID: Self.recordingID)
        await waitUntilFinished(store, recordingID: Self.recordingID)

        let details = store.data(for: Self.recordingID)
        XCTAssertEqual(details?.performers.first?.artists.first?.name, "Performer")
        XCTAssertEqual(details?.technical.first?.names, ["Engineer"])
        XCTAssertTrue(details?.creators.isEmpty == true)
        XCTAssertTrue(details?.workHierarchy.isEmpty == true)
        XCTAssertTrue(store.didFail(Self.recordingID))
    }

    func testFailedWorkEnrichmentCanBeRetried() async {
        let work = MBWork(
            id: Self.workID,
            title: "The Work",
            relations: [
                MBRelation(
                    type: "composer",
                    artist: MBArtist(id: "composer-id", name: "Composer")
                )
            ]
        )
        let service = ScriptedTrackDetailService(
            recording: Self.recording,
            workResults: [
                .failure(MusicBrainzServiceError.serverUnavailable(statusCode: 503)),
                .success(work)
            ]
        )
        let store = TrackDetailStore(service: service)

        store.fetchIfNeeded(recordingID: Self.recordingID)
        await waitUntilFinished(store, recordingID: Self.recordingID)
        XCTAssertTrue(store.didFail(Self.recordingID))

        store.fetchIfNeeded(recordingID: Self.recordingID)
        await waitUntilFinished(store, recordingID: Self.recordingID)

        let details = store.data(for: Self.recordingID)
        XCTAssertEqual(details?.creators.first?.artists.first?.name, "Composer")
        XCTAssertEqual(details?.workHierarchy, ["The Work"])
        XCTAssertFalse(store.didFail(Self.recordingID))
        XCTAssertEqual(service.recordingRequestCount, 1)
        XCTAssertEqual(service.workRequestCount, 2)
    }

    func testCompletedDetailsAreNotFetchedAgain() async {
        let service = ScriptedTrackDetailService(
            recording: MBRecording(id: Self.recordingID),
            workResults: []
        )
        let store = TrackDetailStore(service: service)

        store.fetchIfNeeded(recordingID: Self.recordingID)
        await waitUntilFinished(store, recordingID: Self.recordingID)
        store.fetchIfNeeded(recordingID: Self.recordingID)

        XCTAssertEqual(service.recordingRequestCount, 1)
        XCTAssertNotNil(store.data(for: Self.recordingID))
        XCTAssertFalse(store.isLoading(Self.recordingID))
        XCTAssertFalse(store.didFail(Self.recordingID))
    }

    private func waitUntilFinished(
        _ store: TrackDetailStore,
        recordingID: String
    ) async {
        while store.isLoading(recordingID) {
            await Task.yield()
        }
    }

    private static let recordingID = "recording-id"
    private static let workID = "work-id"
    private static let recording = MBRecording(
        id: recordingID,
        relations: [
            MBRelation(
                type: "instrument",
                artist: MBArtist(id: "performer-id", name: "Performer"),
                attributes: ["guitar"]
            ),
            MBRelation(
                type: "engineer",
                artist: MBArtist(id: "engineer-id", name: "Engineer")
            ),
            MBRelation(
                type: "performance",
                work: MBWorkReference(id: workID, title: "The Work")
            )
        ]
    )
}

@MainActor
private final class ScriptedTrackDetailService: TrackDetailServing {
    let recording: MBRecording
    var workResults: [Result<MBWork, Error>]
    private(set) var recordingRequestCount = 0
    private(set) var workRequestCount = 0

    init(
        recording: MBRecording,
        workResults: [Result<MBWork, Error>]
    ) {
        self.recording = recording
        self.workResults = workResults
    }

    func fetchRecording(id: String) async throws -> MBRecording {
        recordingRequestCount += 1
        return recording
    }

    func fetchWork(id: String) async throws -> MBWork {
        workRequestCount += 1
        guard !workResults.isEmpty else {
            throw MusicBrainzServiceError.unexpected(URLError(.unknown))
        }
        return try workResults.removeFirst().get()
    }
}
