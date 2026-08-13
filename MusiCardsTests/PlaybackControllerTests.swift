import XCTest
@testable import MusiCards

final class PlaybackControllerTests: XCTestCase {
    @MainActor
    func testQueueReplacementClampsIndexAndNavigationStopsAtEdges() async {
        let engine = PlaybackEngineSpy()
        let controller = PlaybackController(engine: engine)
        let items = [item(1), item(2), item(3)]

        let didReplaceQueue = await controller.replaceQueue(
            with: items,
            startingAt: 99
        )
        XCTAssertTrue(didReplaceQueue)
        XCTAssertEqual(controller.currentIndex, 2)
        XCTAssertFalse(controller.hasNext)
        XCTAssertTrue(controller.hasPrevious)

        await controller.selectNext()
        XCTAssertEqual(controller.currentIndex, 2)

        await controller.selectPrevious()
        XCTAssertEqual(controller.currentIndex, 1)
        XCTAssertEqual(controller.position, 0)
    }

    @MainActor
    func testPlayPreparesOnceAndPauseDoesNotPrepareAgain() async {
        let engine = PlaybackEngineSpy()
        let controller = PlaybackController(engine: engine)
        await controller.replaceQueue(with: [item(1)])

        await controller.play()
        XCTAssertEqual(engine.preparedIDs, ["item-1"])
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(controller.status, .playing)

        await controller.pause()
        await controller.play()
        XCTAssertEqual(engine.preparedIDs, ["item-1"])
        XCTAssertEqual(engine.playCount, 2)
    }

    @MainActor
    func testFinishedEventAdvancesAndAutoplaysNextTrack() async {
        let engine = PlaybackEngineSpy()
        let controller = PlaybackController(engine: engine)
        await controller.replaceQueue(with: [item(1), item(2)])
        await controller.play()

        engine.emit(.finished)
        await waitUntil { controller.currentIndex == 1 && controller.status == .playing }

        XCTAssertEqual(engine.preparedIDs, ["item-1", "item-2"])
    }

    @MainActor
    func testFinishedEventStopsAtEndAndRestoresOutput() async {
        let engine = PlaybackEngineSpy()
        let controller = PlaybackController(engine: engine)
        await controller.replaceQueue(with: [item(1)])
        await controller.play()

        engine.emit(.finished)
        await waitUntil { controller.status == .stopped }

        XCTAssertEqual(controller.position, 0)
        XCTAssertEqual(engine.restoreCount, 1)
    }

    @MainActor
    func testSeekClampsToKnownDuration() async {
        let engine = PlaybackEngineSpy()
        let controller = PlaybackController(engine: engine)
        await controller.replaceQueue(with: [item(1, duration: 120)])

        await controller.seek(to: 999)

        XCTAssertEqual(engine.seekPositions, [120])
        XCTAssertEqual(controller.position, 120)
    }

    @MainActor
    private func item(
        _ number: Int,
        duration: TimeInterval = 180
    ) -> PlaybackQueueItem {
        PlaybackQueueItem(
            id: "item-\(number)",
            track: PlaybackTrack(
                id: "track-\(number)",
                releaseTrackID: "release-track-\(number)",
                recordingID: "recording-\(number)",
                releaseID: "release",
                title: "Track \(number)",
                artist: "Artist",
                albumTitle: "Album",
                duration: duration,
                artworkData: nil
            ),
            source: .localFile(
                URL(fileURLWithPath: "/tmp/track-\(number).flac")
            )
        )
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("The expected asynchronous state change did not arrive.")
    }
}

@MainActor
private final class PlaybackEngineSpy: PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    var preparedIDs: [String] = []
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    var restoreCount = 0
    var seekPositions: [TimeInterval] = []

    func prepare(_ item: PlaybackQueueItem) async throws {
        preparedIDs.append(item.id)
        eventHandler?(.prepared(duration: item.track.duration))
    }

    func play() async throws {
        playCount += 1
        eventHandler?(.started)
    }

    func pause() async {
        pauseCount += 1
        eventHandler?(.paused)
    }

    func stop() async {
        stopCount += 1
    }

    func seek(to position: TimeInterval) async throws {
        seekPositions.append(position)
    }

    func restoreOutputConfiguration() {
        restoreCount += 1
    }

    func emit(_ event: PlaybackEngineEvent) {
        eventHandler?(event)
    }
}
