import AudioToolbox
import XCTest
@testable import MusiCards

final class AudioRenderCallbackTests: XCTestCase {
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
