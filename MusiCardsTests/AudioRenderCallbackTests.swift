import AudioToolbox
import XCTest
@testable import MusiCards

final class AudioRenderCallbackTests: XCTestCase {
    func testSignalMeterReadsStereoRMSWithoutChangingSamples() throws {
        let renderer = try XCTUnwrap(MCPPCMRendererCreate(8, 2))
        defer { MCPPCMRendererDestroy(renderer) }
        let samples: [Float] = [0.5, 0.25, -0.5, -0.25, 0.5, 0.25, -0.5, -0.25]
        samples.withUnsafeBufferPointer { XCTAssertEqual(MCPPCMRendererWrite(renderer, $0.baseAddress!, 4), 4) }
        MCPPCMRendererSetPlaying(renderer, true)
        var output = [Float](repeating: 99, count: 8)
        output.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            XCTAssertEqual(MCPPCMRenderCallback(UnsafeMutableRawPointer(renderer), &flags, &timestamp, 0, 4, &buffers), noErr)
        }
        let levels = MCPPCMRendererSignalLevels(renderer)
        XCTAssertEqual(levels.left, 0.5, accuracy: 0.0001)
        XCTAssertEqual(levels.right, 0.25, accuracy: 0.0001)
        XCTAssertEqual(output, samples)
        XCTAssertEqual(MCPPCMRendererCurrentFrame(renderer), 4)
        MCPPCMRendererSetPlaying(renderer, false)
        XCTAssertEqual(MCPPCMRendererSignalLevels(renderer).left, 0)
        XCTAssertEqual(MCPPCMRendererSignalLevels(renderer).right, 0)
        MCPPCMRendererReset(renderer, 0)
        MCPPCMRendererSetPlaying(renderer, true)
        XCTAssertEqual(MCPPCMRendererSignalLevels(renderer).left, 0)
    }

    func testSignalMeterMirrorsMonoAndIncludesUnderrunSilence() throws {
        let renderer = try XCTUnwrap(MCPPCMRendererCreate(4, 1))
        defer { MCPPCMRendererDestroy(renderer) }
        let samples: [Float] = [1, -1]
        samples.withUnsafeBufferPointer { _ = MCPPCMRendererWrite(renderer, $0.baseAddress!, 2) }
        MCPPCMRendererSetPlaying(renderer, true)
        var output = [Float](repeating: 99, count: 4)
        output.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            XCTAssertEqual(MCPPCMRenderCallback(UnsafeMutableRawPointer(renderer), &flags, &timestamp, 0, 4, &buffers), noErr)
        }
        let levels = MCPPCMRendererSignalLevels(renderer)
        XCTAssertEqual(levels.left, Float(sqrt(0.5)), accuracy: 0.0001)
        XCTAssertEqual(levels.right, levels.left)
        XCTAssertEqual(output, [1, -1, 0, 0])
    }

    func testSignalDisplayUsesDecibelsAndRejectsInvalidValues() {
        XCTAssertEqual(PlaybackSignalLevels.displayFraction(1), 1)
        XCTAssertEqual(PlaybackSignalLevels.displayFraction(0.1), 0.6, accuracy: 0.001)
        XCTAssertEqual(PlaybackSignalLevels.displayFraction(0), 0)
        XCTAssertEqual(PlaybackSignalLevels.displayFraction(0.001), 0)
        XCTAssertEqual(PlaybackSignalLevels.displayFraction(.nan), 0)
        XCTAssertEqual(PlaybackSignalLevels(left: .nan, right: .infinity), .silence)
    }
    @MainActor
    func testPauseDuringReplayPreparationCancelsPendingStart() async throws {
        let coordinator = AudioPlaybackOperationCoordinator()
        let latch = SeekOperationLatch()
        var started = false
        let play = Task {
            try await coordinator.play(prepare: { await latch.run() }, start: { started = true })
        }
        await latch.waitUntilEntered()
        coordinator.pause()
        await latch.release()
        do {
            try await play.value
            XCTFail("Pause must win over a pending replay")
        } catch is CancellationError {}
        XCTAssertFalse(started)
    }
    func testConcurrentResetAndRenderPreserveRingCursorBounds() throws {
        nonisolated(unsafe) let renderer = try XCTUnwrap(MCPPCMRendererCreate(8, 1))
        defer { MCPPCMRendererDestroy(renderer) }
        let samples: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        samples.withUnsafeBufferPointer { _ = MCPPCMRendererWrite(renderer, $0.baseAddress!, 8) }
        MCPPCMRendererSetPlaying(renderer, true)
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            if worker == 0 {
                for _ in 0..<20_000 { MCPPCMRendererReset(renderer, 0) }
            } else {
                let output = UnsafeMutablePointer<Float>.allocate(capacity: 4)
                defer { output.deallocate() }
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: 16, mData: output
                ))
                var timestamp = AudioTimeStamp()
                for _ in 0..<20_000 {
                    var flags: AudioUnitRenderActionFlags = []
                    XCTAssertEqual(MCPPCMRenderCallback(UnsafeMutableRawPointer(renderer), &flags, &timestamp, 0, 4, &buffers), noErr)
                    XCTAssertLessThanOrEqual(MCPPCMRendererCurrentFrame(renderer), 8)
                }
            }
        }
        MCPPCMRendererReset(renderer, 0)
        XCTAssertEqual(MCPPCMRendererWritableFrames(renderer), 8)
        XCTAssertEqual(MCPPCMRendererCurrentFrame(renderer), 0)
    }

    @MainActor
    func testSupersededSeeksAreSerializedAndOnlyLatestResumes() async throws {
        let coordinator = AudioPlaybackOperationCoordinator()
        let first = SeekOperationLatch()
        let second = SeekOperationLatch()
        var resumes = 0
        try await coordinator.play {}
        let oldSeek = Task {
            try await coordinator.seek(operation: { await first.run() }, resume: { resumes += 1 })
        }
        await first.waitUntilEntered()
        let queued = expectation(description: "second seek queued")
        let newSeek = Task {
            queued.fulfill()
            try await coordinator.seek(operation: { await second.run() }, resume: { resumes += 1 })
        }
        await fulfillment(of: [queued], timeout: 2)
        await first.release()
        await second.waitUntilEntered()
        XCTAssertEqual(resumes, 0)
        await second.release()
        do {
            try await oldSeek.value
            XCTFail("A superseded seek must not resume output")
        } catch is CancellationError {}
        try await newSeek.value
        XCTAssertEqual(resumes, 1)
    }

    @MainActor
    func testPauseDuringSeekPreventsAutomaticResume() async throws {
        let coordinator = AudioPlaybackOperationCoordinator()
        let latch = SeekOperationLatch()
        var starts = 0
        try await coordinator.play { starts += 1 }
        let seek = Task {
            try await coordinator.seek(operation: { await latch.run() }, resume: { starts += 1 })
        }
        await latch.waitUntilEntered()
        coordinator.pause()
        await latch.release()
        try await seek.value
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testPlayWaitsForPausedSeekAndStartsOnlyOnce() async throws {
        let coordinator = AudioPlaybackOperationCoordinator()
        let latch = SeekOperationLatch()
        var starts = 0
        let seek = Task {
            try await coordinator.seek(operation: { await latch.run() }, resume: { starts += 1 })
        }
        await latch.waitUntilEntered()
        let queued = expectation(description: "Play queued behind seek")
        let play = Task {
            queued.fulfill()
            try await coordinator.play { starts += 1 }
        }
        await fulfillment(of: [queued], timeout: 2)
        XCTAssertEqual(starts, 0)
        await latch.release()
        try await seek.value
        try await play.value
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testStopDuringSeekInvalidatesLateCompletion() async throws {
        let coordinator = AudioPlaybackOperationCoordinator()
        let latch = SeekOperationLatch()
        var resumed = false
        try await coordinator.play {}
        let seek = Task {
            try await coordinator.seek(operation: { await latch.run() }, resume: { resumed = true })
        }
        await latch.waitUntilEntered()
        coordinator.reset()
        await latch.release()
        do {
            try await seek.value
            XCTFail("A stopped session must invalidate the pending seek")
        } catch is CancellationError {}
        XCTAssertFalse(resumed)
        try await coordinator.play {}
    }

    func testCRenderCallbackCanRunOnRealtimeStyleBackgroundQueue() {
        let callback: AURenderCallback = MCPPCMRenderCallback
        nonisolated(unsafe) let backgroundCallback = callback
        let finished = expectation(description: "C render callback returned")

        DispatchQueue(
            label: "test.audio.io",
            qos: .userInteractive
        ).async {
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            let status = backgroundCallback(
                UnsafeMutableRawPointer(bitPattern: 1)!,
                &flags,
                &timestamp,
                0,
                128,
                nil
            )

            XCTAssertEqual(status, kAudio_ParamError)
            finished.fulfill()
        }

        wait(for: [finished], timeout: 2)
    }
}

private actor SeekOperationLatch {
    private var pending: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func run() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    func waitUntilEntered() async {
        if pending != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}
