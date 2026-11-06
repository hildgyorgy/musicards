import AudioToolbox
import XCTest
@testable import MusiCards

/// Exercises the real core, real DecodedPCM feeder and C renderer without
/// installing a device callback. Only the hardware driver and decoder I/O vary.
@MainActor
final class AudioPlaybackCoreLifecycleTests: XCTestCase {
    func testUserSeekSupersedesReplayRewindWithoutLosingPlayIntent() async throws {
        let rewindEntered = expectation(description: "implicit rewind entered")
        let userSeekEntered = expectation(description: "new user seek entered")
        let backend = ControlledPCMBackend(seekEntered: rewindEntered, followingSeekEntered: userSeekEntered)
        defer { backend.releaseSeek(); backend.releaseSeek() }
        let driver = InertAudioOutputDriver()
        let core = AudioUnitPlaybackCore(outputDriver: driver)
        let pcm = try makePCM(backend)
        let unit = AudioUnit(bitPattern: 1)!
        core.completePreparation(decodedPCM: pcm, seekCapability: .supported, audioFormatHint: nil)
        core.installOutputUnit(unit)
        MCPPCMRendererSetPlaying(pcm.renderer, true)
        MCPPCMRendererMarkEndOfStream(pcm.renderer)
        var output: [Float] = [0, 0]
        output.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            _ = MCPPCMRenderCallback(UnsafeMutableRawPointer(pcm.renderer), &flags, &timestamp, 0, 1, &buffers)
        }
        XCTAssertTrue(MCPPCMRendererDidFinish(pcm.renderer))
        let play = Task { try await core.play { try self.start(core, pcm: pcm, unit: unit) } }
        await fulfillment(of: [rewindEntered], timeout: 2)
        let requested = expectation(description: "user seek requested during rewind")
        let seek = Task {
            requested.fulfill()
            try await core.seek(to: 0.002) { try self.start(core, pcm: pcm, unit: unit) }
        }
        await fulfillment(of: [requested], timeout: 2)
        backend.releaseSeek()
        await fulfillment(of: [userSeekEntered], timeout: 2)
        XCTAssertFalse(core.isOutputRunning)
        backend.releaseSeek()
        try await seek.value
        try await play.value
        XCTAssertEqual(backend.seekFrames, [0, 88])
        XCTAssertEqual(MCPPCMRendererCurrentFrame(pcm.renderer), 88)
        XCTAssertEqual(driver.events, ["start"])
        await core.stop()
    }
    func testStoppedSessionKeepsDecoderAliveOnlyUntilBlockedSeekReturns() async throws {
        let entered = expectation(description: "seek entered")
        let backend = ControlledPCMBackend(seekEntered: entered)
        defer { backend.releaseSeek() }
        let core = AudioUnitPlaybackCore(outputDriver: InertAudioOutputDriver())
        var pcm: DecodedPCM? = try makePCM(backend)
        weak var retainedSession = pcm
        core.completePreparation(decodedPCM: pcm!, seekCapability: .supported, audioFormatHint: nil)
        let seek = Task { try await core.seek(to: 0.001) { XCTFail("Disposed session resumed") } }
        await fulfillment(of: [entered], timeout: 2)
        pcm = nil
        await core.stop()
        XCTAssertTrue(backend.wasCancelled)
        XCTAssertNotNil(retainedSession, "In-flight decoder must retain the buffers it uses")
        backend.releaseSeek()
        do {
            try await seek.value
            XCTFail("Stopped seek must be cancelled")
        } catch is CancellationError {}
        XCTAssertNil(retainedSession, "A completed cancelled seek must release its decoder and renderer")
    }
    func testPauseWinsWhileActualDecoderSeekIsBlocked() async throws {
        let entered = expectation(description: "decoder seek entered")
        let backend = ControlledPCMBackend(seekEntered: entered)
        defer { backend.releaseSeek() }
        let driver = InertAudioOutputDriver()
        let core = AudioUnitPlaybackCore(outputDriver: driver)
        let pcm = try makePCM(backend)
        let unit = AudioUnit(bitPattern: 1)!
        core.completePreparation(decodedPCM: pcm, seekCapability: .supported, audioFormatHint: nil)
        core.installOutputUnit(unit)
        try await core.play { try self.start(core, pcm: pcm, unit: unit) }
        let seek = Task { try await core.seek(to: 0.001) { try self.start(core, pcm: pcm, unit: unit) } }
        await fulfillment(of: [entered], timeout: 2)
        core.pause()
        backend.releaseSeek()
        try await seek.value
        XCTAssertFalse(core.isOutputRunning)
        XCTAssertEqual(driver.events, ["start", "stop"])
        await core.stop()
        XCTAssertEqual(driver.events.last, "dispose")
    }

    func testExplicitPlayWaitsForActualDecoderSeek() async throws {
        let entered = expectation(description: "decoder seek entered")
        let backend = ControlledPCMBackend(seekEntered: entered)
        defer { backend.releaseSeek() }
        let driver = InertAudioOutputDriver()
        let core = AudioUnitPlaybackCore(outputDriver: driver)
        let pcm = try makePCM(backend)
        let unit = AudioUnit(bitPattern: 1)!
        core.completePreparation(decodedPCM: pcm, seekCapability: .supported, audioFormatHint: nil)
        core.installOutputUnit(unit)
        let seek = Task { try await core.seek(to: 0.001) { try self.start(core, pcm: pcm, unit: unit) } }
        await fulfillment(of: [entered], timeout: 2)
        let requested = expectation(description: "Play requested")
        let play = Task {
            requested.fulfill()
            try await core.play { try self.start(core, pcm: pcm, unit: unit) }
        }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertTrue(driver.events.isEmpty, "Output must stay stopped while the ring is being reset")
        backend.releaseSeek()
        try await seek.value
        try await play.value
        XCTAssertEqual(driver.events, ["start"])
        await core.stop()
        XCTAssertEqual(driver.events, ["start", "stop", "dispose"])
    }

    func testOldBlockedSeekCannotDelayOrTearDownNewDecoderSession() async throws {
        let entered = expectation(description: "old decoder seek entered")
        let oldBackend = ControlledPCMBackend(seekEntered: entered)
        defer { oldBackend.releaseSeek() }
        let driver = InertAudioOutputDriver()
        let core = AudioUnitPlaybackCore(outputDriver: driver)
        let oldPCM = try makePCM(oldBackend)
        let unit = AudioUnit(bitPattern: 1)!
        core.completePreparation(decodedPCM: oldPCM, seekCapability: .supported, audioFormatHint: nil)
        core.installOutputUnit(unit)
        try await core.play { try self.start(core, pcm: oldPCM, unit: unit) }
        let oldSeek = Task { try await core.seek(to: 0.001) { XCTFail("Old output resumed") } }
        await fulfillment(of: [entered], timeout: 2)

        await core.stop()
        XCTAssertTrue(oldBackend.wasCancelled)
        XCTAssertEqual(driver.events, ["start", "stop", "dispose"])
        let newPCM = try makePCM(ControlledPCMBackend())
        _ = try await core.beginPreparation()
        core.completePreparation(decodedPCM: newPCM, seekCapability: .supported, audioFormatHint: nil)
        core.installOutputUnit(unit)
        // This must complete before releasing old decoder I/O.
        try await core.play { try self.start(core, pcm: newPCM, unit: unit) }
        XCTAssertTrue(core.isOutputRunning)
        oldBackend.releaseSeek()
        do {
            try await oldSeek.value
            XCTFail("Replaced seek must be cancelled")
        } catch is CancellationError {}
        XCTAssertTrue(core.decodedPCM === newPCM)
        XCTAssertTrue(core.isOutputRunning)
        XCTAssertEqual(driver.events, ["start", "stop", "dispose", "start"])
        await core.stop()
    }

    func testOutputFailureDoesNotLeaveAutomaticResumeIntent() async throws {
        let driver = InertAudioOutputDriver()
        driver.startStatus = kAudio_ParamError
        let core = AudioUnitPlaybackCore(outputDriver: driver)
        let pcm = try makePCM(ControlledPCMBackend())
        let unit = AudioUnit(bitPattern: 1)!
        core.completePreparation(decodedPCM: pcm, seekCapability: .supported, audioFormatHint: nil)
        core.installOutputUnit(unit)
        do {
            try await core.play { try self.start(core, pcm: pcm, unit: unit) }
            XCTFail("Expected output failure")
        } catch is NativePlaybackEngineError {}
        driver.startStatus = noErr
        try await core.seek(to: 0.001) { XCTFail("Failed Play left an automatic resume request") }
        XCTAssertFalse(core.isOutputRunning)
        await core.stop()
    }

    func testInvalidSeekIsRejectedBeforeDecoderMutation() async throws {
        let core = AudioUnitPlaybackCore(outputDriver: InertAudioOutputDriver())
        let pcm = try makePCM(ControlledPCMBackend())
        core.completePreparation(decodedPCM: pcm, seekCapability: .supported, audioFormatHint: nil)
        do {
            try await core.seek(to: .nan) { XCTFail("Invalid seek resumed") }
            XCTFail("Invalid seek accepted")
        } catch is NativePlaybackEngineError {}
        XCTAssertEqual(MCPPCMRendererCurrentFrame(pcm.renderer), 0)
        await core.stop()
    }

    private func makePCM(_ backend: ControlledPCMBackend) throws -> DecodedPCM {
        DecodedPCM(
            renderer: try XCTUnwrap(MCPPCMRendererCreate(16, 2)),
            sampleRate: 44_100, channelCount: 2, frameCount: 100_000,
            decoder: backend, decodeBuffer: .allocate(capacity: 8),
            decodeChunkFrames: 4, didAccessSecurityScope: false, sourceURL: nil
        )
    }

    private func start(_ core: AudioUnitPlaybackCore, pcm: DecodedPCM, unit: AudioUnit) throws {
        MCPPCMRendererSetPlaying(pcm.renderer, true)
        try core.startOutputUnit(unit, failureMessage: "Test output failure")
    }
}

@MainActor
private final class InertAudioOutputDriver: AudioUnitOutputDriving {
    var events: [String] = []
    var startStatus: OSStatus = noErr
    func start(_ unit: AudioUnit) -> OSStatus { events.append("start"); return startStatus }
    func stop(_ unit: AudioUnit) -> OSStatus { events.append("stop"); return noErr }
    func dispose(_ unit: AudioUnit) { events.append("dispose") }
}

/// Intentionally slow cancellation: the old decoder can remain blocked even
/// after cancel, to prove that it cannot control a replacement session.
private nonisolated final class ControlledPCMBackend: PCMDecoderBackend, @unchecked Sendable {
    let format = PCMDecoderFormat(sampleRate: 44_100, channelCount: 2, sampleFormat: .interleavedFloat32)
    let frameCount: UInt64 = 100_000
    let isRemote = true
    let seekCapabilityOverride: PlaybackSeekCapability? = .supported
    private let seekEntered: XCTestExpectation?
    private let followingSeekEntered: XCTestExpectation?
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false
    private var frames: [UInt64] = []
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var seekFrames: [UInt64] { lock.withLock { frames } }

    init(seekEntered: XCTestExpectation? = nil, followingSeekEntered: XCTestExpectation? = nil) {
        self.seekEntered = seekEntered
        self.followingSeekEntered = followingSeekEntered
    }
    func read(into buffer: UnsafeMutableRawPointer, frameCapacity: UInt32) throws -> UInt32 {
        if wasCancelled { throw CancellationError() }
        buffer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: Int(frameCapacity) * 2)
        return frameCapacity
    }
    func seek(to frame: UInt64) throws {
        let call = lock.withLock { frames.append(frame); return frames.count }
        let entered = call == 1 ? seekEntered : followingSeekEntered
        if let entered {
            entered.fulfill()
            guard gate.wait(timeout: .now() + 10) == .success else { throw URLError(.timedOut) }
        }
        if wasCancelled { throw CancellationError() }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func releaseSeek() { gate.signal() }
    func beginSeek() {}
    func endSeek(succeeded: Bool) {}
    func takeReadError() -> Error? { nil }
    func didProduceFirstPCM() {}
}
