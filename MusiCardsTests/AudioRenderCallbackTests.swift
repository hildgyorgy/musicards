import AudioToolbox
import XCTest
@testable import MusiCards

final class AudioRenderCallbackTests: XCTestCase {
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
