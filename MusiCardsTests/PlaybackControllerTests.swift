import Foundation
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
    func testStopThenPlayPreparesARecoverableFreshSession() async {
        let engine = PlaybackEngineSpy()
        let controller = PlaybackController(engine: engine)
        await controller.replaceQueue(with: [item(1)])

        await controller.play()
        await controller.stop()
        await controller.play()

        XCTAssertEqual(engine.preparedIDs, ["item-1", "item-1"])
        XCTAssertEqual(engine.playCount, 2)
        XCTAssertEqual(controller.status, .playing)
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
    func testRemoteFLACSeekIsRejectedWithoutPoisoningReplayOrQueueNavigation() async throws {
        let engine = PlaybackEngineSpy()
        let flacReference = PlaybackAssetReference(
            source: .navidrome,
            providerItemID: "remote-flac",
            displayName: "NAVIDROME",
            seekCapability: .remoteMedia(
                suffix: "flac",
                contentType: "audio/flac"
            )
        )
        let alacReference = PlaybackAssetReference(
            source: .navidrome,
            providerItemID: "remote-alac",
            displayName: "NAVIDROME",
            seekCapability: .remoteMedia(
                suffix: "m4a",
                contentType: "audio/mp4"
            )
        )
        let flacAsset = try remoteAsset(
            id: "remote-flac",
            suffix: "flac",
            contentType: "audio/flac"
        )
        let alacAsset = try remoteAsset(
            id: "remote-alac",
            suffix: "m4a",
            contentType: "audio/mp4"
        )
        let resolver = PlaybackAssetResolverSpy(
            sources: [
                flacReference: .remoteAudio(flacAsset.asset),
                alacReference: .remoteAudio(alacAsset.asset)
            ]
        )
        let controller = PlaybackController(
            engine: engine,
            assetResolver: resolver
        )
        let flacItem = PlaybackQueueItem(
            id: "flac-item",
            track: item(1).track,
            source: .libraryAsset(flacReference)
        )
        let alacItem = PlaybackQueueItem(
            id: "alac-item",
            track: item(2).track,
            source: .libraryAsset(alacReference)
        )

        await controller.replaceQueue(with: [flacItem, alacItem])
        await controller.play()
        XCTAssertEqual(controller.status, .playing)
        XCTAssertFalse(controller.canSeek)

        await controller.seek(to: 60)
        XCTAssertTrue(engine.seekPositions.isEmpty)
        XCTAssertEqual(controller.status, .playing)

        await controller.stop()
        await controller.play()
        XCTAssertEqual(engine.preparedIDs, ["flac-item", "flac-item"])
        XCTAssertEqual(controller.status, .playing)

        await controller.selectNext(autoplay: true)
        XCTAssertEqual(controller.currentItem?.id, "alac-item")
        XCTAssertTrue(controller.canSeek)
        await controller.seek(to: 60)
        XCTAssertEqual(engine.seekPositions, [60])

        await controller.selectPrevious(autoplay: true)
        XCTAssertEqual(controller.currentItem?.id, "flac-item")
        XCTAssertEqual(controller.status, .playing)

        flacAsset.source.cancel()
        alacAsset.source.cancel()
    }

    @MainActor
    func testSupportedSeekFailureAllowsFreshPrepareAndAnotherTrack() async {
        let engine = PlaybackEngineSpy()
        let controller = PlaybackController(engine: engine)
        await controller.replaceQueue(with: [item(1), item(2)])
        await controller.play()
        engine.seekError = PlaybackTestError.seekFailed

        await controller.seek(to: 60)
        guard case .failed = controller.status else {
            return XCTFail("Expected failed seek state")
        }

        engine.seekError = nil
        await controller.play()
        XCTAssertEqual(engine.preparedIDs, ["item-1", "item-1"])
        XCTAssertEqual(controller.status, .playing)

        await controller.selectNext(autoplay: true)
        XCTAssertEqual(controller.currentItem?.id, "item-2")
        XCTAssertEqual(controller.status, .playing)
    }

    @MainActor
    func testLibraryAssetIsResolvedLazilyAndPreparedOnlyOnce() async {
        let engine = PlaybackEngineSpy()
        let reference = PlaybackAssetReference(
            source: .local,
            providerItemID: "local-item",
            displayName: "LOCAL"
        )
        let resolvedURL = URL(fileURLWithPath: "/tmp/resolved.flac")
        let resolver = PlaybackAssetResolverSpy(
            sources: [reference: .localFile(resolvedURL)]
        )
        let controller = PlaybackController(
            engine: engine,
            assetResolver: resolver
        )
        let unresolvedItem = PlaybackQueueItem(
            id: "item-1",
            track: item(1).track,
            source: .libraryAsset(reference)
        )

        await controller.replaceQueue(with: [unresolvedItem])

        XCTAssertTrue(resolver.references.isEmpty)
        await controller.play()
        XCTAssertEqual(resolver.references, [reference])
        XCTAssertEqual(engine.preparedSources, [.localFile(resolvedURL)])
        XCTAssertEqual(controller.queue.first?.source, .libraryAsset(reference))

        await controller.pause()
        await controller.play()
        XCTAssertEqual(resolver.references, [reference])
        XCTAssertEqual(engine.preparedSources, [.localFile(resolvedURL)])
    }

    @MainActor
    func testRemoteLibraryAssetIsResolvedLazily() async throws {
        let engine = PlaybackEngineSpy()
        let reference = PlaybackAssetReference(
            source: .navidrome,
            providerItemID: "remote-song",
            displayName: "NAVIDROME"
        )
        let byteSource = try HTTPRandomAccessByteSource(
            baseRequest: URLRequest(
                url: URL(string: "https://example.invalid/rest/stream")!
            ),
            length: 1
        )
        let remoteAsset = RemotePlaybackAsset(
            source: .navidrome,
            providerItemID: "remote-song",
            displayName: "NAVIDROME",
            mediaSize: 1,
            suffix: "flac",
            contentType: "audio/flac",
            byteSourceProvider: ControllerRemoteByteSourceProviderStub(
                source: byteSource
            )
        )
        let resolver = PlaybackAssetResolverSpy(
            sources: [reference: .remoteAudio(remoteAsset)]
        )
        let controller = PlaybackController(
            engine: engine,
            assetResolver: resolver
        )
        let unresolvedItem = PlaybackQueueItem(
            id: "remote-item",
            track: item(1).track,
            source: .libraryAsset(reference)
        )

        await controller.replaceQueue(with: [unresolvedItem])
        await controller.play()

        XCTAssertEqual(resolver.references, [reference])
        XCTAssertEqual(
            engine.preparedSources,
            [.remoteAudio(remoteAsset)]
        )
        byteSource.cancel()
    }

    @MainActor
    func testStaleAssetResolutionDoesNotStopNewerQueue() async {
        let engine = PlaybackEngineSpy()
        let resolver = SuspendedPlaybackAssetResolver()
        let reference = PlaybackAssetReference(
            source: .local,
            providerItemID: "delayed-item",
            displayName: "LOCAL"
        )
        let controller = PlaybackController(
            engine: engine,
            assetResolver: resolver
        )
        let delayedItem = PlaybackQueueItem(
            id: "delayed",
            track: item(1).track,
            source: .libraryAsset(reference)
        )

        await controller.replaceQueue(with: [delayedItem])
        let stalePlay = Task { @MainActor in
            await controller.play()
        }
        await waitUntil { resolver.hasPendingResolution }

        await controller.replaceQueue(with: [item(2)])
        let stopCountAfterReplacement = engine.stopCount
        resolver.resolve(with: .localFile(
            URL(fileURLWithPath: "/tmp/delayed.flac")
        ))
        await stalePlay.value

        XCTAssertTrue(engine.preparedIDs.isEmpty)
        XCTAssertEqual(engine.stopCount, stopCountAfterReplacement)
        XCTAssertEqual(controller.currentItem?.id, "item-2")
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
    private func remoteAsset(
        id: String,
        suffix: String,
        contentType: String
    ) throws -> (
        asset: RemotePlaybackAsset,
        source: HTTPRandomAccessByteSource
    ) {
        let source = try HTTPRandomAccessByteSource(
            baseRequest: URLRequest(
                url: URL(string: "https://example.invalid/rest/stream")!
            ),
            length: 1
        )
        return (
            RemotePlaybackAsset(
                source: .navidrome,
                providerItemID: id,
                displayName: "NAVIDROME",
                mediaSize: 1,
                suffix: suffix,
                contentType: contentType,
                byteSourceProvider: ControllerRemoteByteSourceProviderStub(
                    source: source
                )
            ),
            source
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
    var canSeek = false
    var preparedIDs: [String] = []
    var preparedSources: [PlaybackSource] = []
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    var restoreCount = 0
    var seekPositions: [TimeInterval] = []
    var seekError: Error?

    func prepare(_ item: PlaybackQueueItem) async throws {
        preparedIDs.append(item.id)
        preparedSources.append(item.source)
        canSeek = item.source.seekCapability.isSupported
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
        if let seekError { throw seekError }
        seekPositions.append(position)
    }

    func restoreOutputConfiguration() {
        restoreCount += 1
    }

    func emit(_ event: PlaybackEngineEvent) {
        eventHandler?(event)
    }
}

private enum PlaybackTestError: Error {
    case seekFailed
}

@MainActor
private final class PlaybackAssetResolverSpy: PlaybackAssetResolving {
    let sources: [PlaybackAssetReference: PlaybackSource]
    var references = [PlaybackAssetReference]()

    init(sources: [PlaybackAssetReference: PlaybackSource]) {
        self.sources = sources
    }

    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource {
        references.append(reference)
        guard let source = sources[reference] else {
            throw PlaybackAssetResolutionError.assetUnavailable
        }
        return source
    }
}

@MainActor
private final class SuspendedPlaybackAssetResolver: PlaybackAssetResolving {
    private var continuation: CheckedContinuation<PlaybackSource, Error>?

    var hasPendingResolution: Bool {
        continuation != nil
    }

    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(with source: PlaybackSource) {
        continuation?.resume(returning: source)
        continuation = nil
    }
}

@MainActor
private final class ControllerRemoteByteSourceProviderStub:
    RemoteAudioByteSourceProviding
{
    private let source: HTTPRandomAccessByteSource

    init(source: HTTPRandomAccessByteSource) {
        self.source = source
    }

    func makeByteSource() throws -> HTTPRandomAccessByteSource {
        source
    }
}
