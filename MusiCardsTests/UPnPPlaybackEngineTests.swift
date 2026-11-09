import Foundation
import XCTest
@testable import MusiCards

final class UPnPPlaybackEngineTests: XCTestCase {
    @MainActor
    func testFailedConnectionPreflightCannotResumePreparedSystemAudio() async throws {
        let system = MeteringSystemEngine()
        var available = true
        let routing = OutputRoutingPlaybackEngine(
            systemEngine: system, rendererEngine: makeEngine(client: TransportSpy()),
            selection: { .system },
            validatePlayback: {
                if !available { throw NavidromeConnectionStoreError.serverUnavailable }
            }
        )
        try await routing.prepare(makeItem("first"))
        available = false
        do {
            try await routing.play()
            XCTFail("A prepared item must not bypass the connection check")
        } catch {
            XCTAssertEqual(error as? NavidromeConnectionStoreError, .serverUnavailable)
        }
        XCTAssertEqual(system.playCount, 0)
    }

    @MainActor
    func testUnavailableRendererNeverFallsBackToSystemAudio() async throws {
        let system = MeteringSystemEngine()
        let routing = OutputRoutingPlaybackEngine(
            systemEngine: system, rendererEngine: makeEngine(client: TransportSpy()),
            selection: { .unavailable(name: "AVM") }
        )
        do {
            try await routing.prepare(makeItem("first"))
            XCTFail("The user must explicitly select System audio")
        } catch {}
        XCTAssertEqual(system.prepareCount, 0)
        XCTAssertEqual(system.playCount, 0)
    }
    @MainActor
    func testMeterRequestFollowsOnlyTheActiveSystemRoute() async throws {
        let system = MeteringSystemEngine()
        var selection: OutputRoutingPlaybackEngine.Selection = .system
        let routing = OutputRoutingPlaybackEngine(
            systemEngine: system,
            rendererEngine: makeEngine(client: TransportSpy()),
            selection: { selection }
        )
        routing.setSignalMeteringEnabled(true)
        XCTAssertFalse(system.meteringEnabled)
        try await routing.prepare(makeItem("first"))
        XCTAssertTrue(system.meteringEnabled)
        selection = .renderer(makeRenderer())
        try await routing.prepare(makeItem("first"))
        XCTAssertFalse(system.meteringEnabled)
        routing.setSignalMeteringEnabled(true)
        XCTAssertFalse(system.meteringEnabled, "A visible UPnP player must not measure local PCM")
        selection = .system
        try await routing.prepare(makeItem("first"))
        XCTAssertTrue(system.meteringEnabled)
        await routing.stop()
        XCTAssertFalse(system.meteringEnabled)
    }
    @MainActor
    func testEarlyRendererStopDoesNotFinishOrConsumeQueue() async throws {
        let client = TransportSpy()
        let engine = makeEngine(client: client)
        engine.configure(renderer: makeRenderer())
        try await engine.prepare(makeItem("first"))
        await client.setSnapshots([
            Self.snapshot(state: "PLAYING", songID: "first", position: 10),
            Self.snapshot(state: "STOPPED", songID: "first", position: 10)
        ])
        var events: [PlaybackEngineEvent] = []
        engine.eventHandler = { events.append($0) }
        await engine.pollRenderer()
        await engine.pollRenderer()
        XCTAssertTrue(events.contains(.paused))
        XCTAssertFalse(events.contains(.finished))
        await engine.stop()
    }
    @MainActor
    func testPrepareStagesNextTrackAndPublishesPreparedEvent() async throws {
        let client = TransportSpy()
        let engine = makeEngine(client: client)
        engine.configure(renderer: makeRenderer(supportsSetNext: true))
        engine.nextItemProvider = { self.makeItem("next") }
        let item = makeItem("first", title: "One & Two")
        var events = [PlaybackEngineEvent]()
        engine.eventHandler = { events.append($0) }

        try await engine.prepare(item)

        let commands = await client.commands
        XCTAssertEqual(commands.count, 2)
        guard case let .setURI(uri, metadata) = commands[0],
              case let .setNext(nextURI) = commands[1] else {
            return XCTFail("Prepare should set the current and next track")
        }
        XCTAssertEqual(UPnPPlaybackEngine.navidromeSongID(in: uri), "first")
        XCTAssertEqual(UPnPPlaybackEngine.navidromeSongID(in: nextURI), "next")
        XCTAssertTrue(metadata.contains("<dc:title>One &amp; Two</dc:title>"))
        XCTAssertEqual(events, [.prepared(duration: 180, audioFormat: nil)])
    }

    @MainActor
    func testPlayPauseSeekAndStopSendTransportCommandsAndEvents() async throws {
        let client = TransportSpy()
        let engine = makeEngine(client: client)
        engine.configure(renderer: makeRenderer())
        var events = [PlaybackEngineEvent]()
        engine.eventHandler = { events.append($0) }

        try await engine.prepare(makeItem("first"))
        try await engine.play()
        await engine.pause()
        try await engine.seek(to: 42)
        await engine.stop()

        let commands = await client.commands
        XCTAssertEqual(commands.map(\.kind), [
            "setURI", "play", "pause", "seek", "stop"
        ])
        XCTAssertEqual(commands[3], .seek(42))
        XCTAssertEqual(events, [
            .prepared(duration: 180, audioFormat: nil),
            .started,
            .paused,
            .positionChanged(42)
        ])
    }

    @MainActor
    func testUnsupportedSourceDoesNotContactRenderer() async {
        let client = TransportSpy()
        let engine = makeEngine(client: client)
        engine.configure(renderer: makeRenderer())
        let localItem = PlaybackQueueItem(
            track: makeItem("first").track,
            source: .localFile(URL(fileURLWithPath: "/tmp/test.flac"))
        )

        do {
            try await engine.prepare(localItem)
            XCTFail("A network renderer must reject a local file")
        } catch UPnPPlaybackError.navidromeOnly {
            // Expected: renderer stream URLs are Navidrome-only.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let commands = await client.commands
        XCTAssertTrue(commands.isEmpty)
    }

    @MainActor
    func testRendererAdvancingToStagedTrackDoesNotReplaceTransportURI() async throws {
        let client = TransportSpy()
        let engine = makeEngine(client: client)
        engine.configure(renderer: makeRenderer(supportsSetNext: true))
        engine.nextItemProvider = { self.makeItem("next") }
        let advanced = expectation(description: "renderer advanced to staged track")
        engine.eventHandler = { event in
            if case .advancedToNext(
                itemID: "next", duration: 180,
                audioFormat: nil, position: 3
            ) = event {
                advanced.fulfill()
            }
        }
        try await engine.prepare(makeItem("first"))
        await client.setSnapshots([
            Self.snapshot(state: "PLAYING", songID: "next", position: 3)
        ])

        try await engine.play()
        await fulfillment(of: [advanced], timeout: 3)
        await engine.stop()

        let commands = await client.commands
        XCTAssertEqual(commands.filter { $0.kind == "setURI" }.count, 1)
        XCTAssertEqual(commands.filter { $0.kind == "setNext" }.count, 2)
    }

    @MainActor
    func testThreeConsecutivePollFailuresPublishFailure() async throws {
        let client = TransportSpy()
        let engine = makeEngine(client: client)
        engine.configure(renderer: makeRenderer())
        await client.failSnapshots()
        let failed = expectation(description: "polling failure published")
        engine.eventHandler = { event in
            if case .failed = event { failed.fulfill() }
        }

        try await engine.prepare(makeItem("first"))
        try await engine.play()
        await fulfillment(of: [failed], timeout: 5)
        await engine.stop()

        let snapshotCount = await client.snapshotCount
        XCTAssertEqual(snapshotCount, 3)
    }

    @MainActor
    func testRendererStoppingAfterPlayingPublishesFinishedOnce() async throws {
        let client = TransportSpy()
        let engine = makeEngine(client: client)
        engine.configure(renderer: makeRenderer())
        await client.setSnapshots([
            Self.snapshot(state: "PLAYING", songID: "first", position: 179),
            Self.snapshot(state: "STOPPED", songID: "first", position: 180)
        ])
        let finished = expectation(description: "renderer finished track")
        var finishedCount = 0
        engine.eventHandler = { event in
            if case .finished = event {
                finishedCount += 1
                finished.fulfill()
            }
        }

        try await engine.prepare(makeItem("first"))
        try await engine.play()
        await fulfillment(of: [finished], timeout: 4)
        await engine.stop()

        XCTAssertEqual(finishedCount, 1)
        let snapshotCount = await client.snapshotCount
        XCTAssertEqual(snapshotCount, 2)
    }

    @MainActor
    func testAdoptingExistingRendererSessionDoesNotReplaceTrack() async throws {
        let client = TransportSpy()
        let engine = makeEngine(client: client)
        engine.configure(renderer: makeRenderer())
        let item = makeItem("first")
        let snapshot = Self.snapshot(
            state: "PLAYING", songID: "first", position: 67
        )
        var events = [PlaybackEngineEvent]()
        engine.eventHandler = { events.append($0) }

        try await engine.adoptRendererSession(item: item, snapshot: snapshot)
        await engine.stop()

        let commands = await client.commands
        XCTAssertEqual(commands, [.stop])
        XCTAssertEqual(events, [
            .prepared(duration: 180, audioFormat: nil),
            .positionChanged(67),
            .started
        ])
    }

    @MainActor
    private func makeEngine(client: TransportSpy) -> UPnPPlaybackEngine {
        UPnPPlaybackEngine(
            streamURLProvider: NavidromeRendererStreamURLProvider(
                connection: RendererConnectionStub()
            ),
            clientFactory: { _ in client }
        )
    }

    private func makeRenderer(
        supportsSetNext: Bool = false
    ) -> UPnPRendererDescriptor {
        let baseURL = URL(string: "http://192.168.1.20:1400")!
        let transport = UPnPServiceDescriptor(
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            serviceID: nil,
            controlURL: baseURL.appending(path: "control"),
            eventSubscriptionURL: nil,
            serviceDescriptionURL: nil
        )
        return UPnPRendererDescriptor(
            friendlyName: "Test Renderer",
            uniqueDeviceName: "uuid:test-renderer",
            manufacturer: nil,
            modelName: nil,
            descriptionURL: baseURL.appending(path: "device.xml"),
            avTransport: transport,
            renderingControl: nil,
            connectionManager: nil,
            capabilities: UPnPRendererCapabilities(
                avTransportActions: supportsSetNext
                    ? ["SetNextAVTransportURI"] : []
            )
        )
    }

    @MainActor
    private func makeItem(
        _ id: String,
        title: String = "Test Track"
    ) -> PlaybackQueueItem {
        let track = PlaybackTrack(
            id: id,
            releaseTrackID: nil,
            recordingID: nil,
            releaseID: nil,
            title: title,
            artist: "Test Artist",
            albumTitle: "Test Album",
            duration: 180,
            artworkData: nil
        )
        let asset = RemotePlaybackAsset(
            source: .navidrome,
            providerItemID: id,
            displayName: "NAVIDROME",
            mediaSize: 1,
            suffix: "flac",
            contentType: "audio/flac",
            byteSourceProvider: UnusedByteSourceProvider()
        )
        return PlaybackQueueItem(track: track, source: .remoteAudio(asset))
    }

    private static func snapshot(
        state: String,
        songID: String,
        position: TimeInterval
    ) -> AVTransportSnapshot {
        AVTransportSnapshot(
            transport: AVTransportStatus(
                state: state, status: nil, speed: nil
            ),
            position: AVTransportPosition(
                trackNumber: 1,
                duration: 180,
                relativeTime: position,
                trackURI: URL(string: "http://192.168.1.10/stream?id=\(songID)")
            )
        )
    }
}

@MainActor
private final class MeteringSystemEngine: PlaybackEngine {
    var eventHandler: ((PlaybackEngineEvent) -> Void)?
    var canSeek: Bool { true }
    private(set) var meteringEnabled = false
    private(set) var prepareCount = 0
    private(set) var playCount = 0
    func prepare(_ item: PlaybackQueueItem) async throws { prepareCount += 1 }
    func play() async throws { playCount += 1 }
    func pause() async {}
    func stop() async {}
    func seek(to position: TimeInterval) async throws {}
    func setSignalMeteringEnabled(_ enabled: Bool) { meteringEnabled = enabled }
}

@MainActor
private final class RendererConnectionStub: NavidromeCatalogConnectionProviding {
    func catalogCredentials() throws -> NavidromeCatalogCredentials {
        NavidromeCatalogCredentials(
            profile: NavidromeServerProfile(
                name: "Test",
                baseURL: URL(string: "http://192.168.1.10")!,
                username: "test"
            ),
            password: "test"
        )
    }
}

@MainActor
private final class UnusedByteSourceProvider: RemoteAudioByteSourceProviding {
    func makeByteSource() throws -> HTTPRandomAccessByteSource {
        throw URLError(.unsupportedURL)
    }
}

private actor TransportSpy: AVTransportControlling {
    enum Command: Equatable {
        case setURI(URL, String)
        case setNext(URL?)
        case play
        case pause
        case stop
        case seek(TimeInterval)

        var kind: String {
            switch self {
            case .setURI: "setURI"
            case .setNext: "setNext"
            case .play: "play"
            case .pause: "pause"
            case .stop: "stop"
            case .seek: "seek"
            }
        }
    }

    private(set) var commands = [Command]()
    private(set) var snapshotCount = 0
    private var snapshots = [AVTransportSnapshot]()
    private var shouldFailSnapshots = false

    func setSnapshots(_ snapshots: [AVTransportSnapshot]) {
        self.snapshots = snapshots
    }

    func failSnapshots() {
        shouldFailSnapshots = true
    }

    func snapshot() async throws -> AVTransportSnapshot {
        snapshotCount += 1
        if shouldFailSnapshots { throw URLError(.cannotConnectToHost) }
        guard !snapshots.isEmpty else { throw URLError(.badServerResponse) }
        return snapshots.removeFirst()
    }

    func setTransportURI(_ uri: URL, metadata: String) async throws {
        commands.append(.setURI(uri, metadata))
    }

    func setNextTransportURI(_ uri: URL?, metadata: String) async throws {
        commands.append(.setNext(uri))
    }

    func play() async throws { commands.append(.play) }
    func pause() async throws { commands.append(.pause) }
    func stop() async throws { commands.append(.stop) }
    func seek(to position: TimeInterval) async throws {
        commands.append(.seek(position))
    }
}
