import AudioToolbox
import XCTest
@testable import MusiCards

@MainActor
final class PlaybackSpectrumAnalyzerTests: XCTestCase {
    func testStereoTonesHaveIndependentLowAndHighFrequencyPeaks() {
        let analyzer = PlaybackSpectrumAnalyzer()
        let stereo = (0..<2048).flatMap { index -> [Float] in
            let phase = 2 * Double.pi * Double(index) / 48_000
            return [Float(0.5 * sin(187.5 * phase)), Float(0.25 * sin(6000 * phase))]
        }
        let bands = analyzer.analyze(stereo: stereo, sampleRate: 48_000)
        XCTAssertEqual(bands.left.count, 24)
        let leftPeak = bands.left.indices.max { bands.left[$0] < bands.left[$1] }!
        let rightPeak = bands.right.indices.max { bands.right[$0] < bands.right[$1] }!
        XCTAssertLessThan(leftPeak, 7)
        XCTAssertGreaterThan(rightPeak, 17)
        XCTAssertGreaterThan(bands.left[leftPeak], 0.7)
        XCTAssertLessThan(bands.right[leftPeak], 0.1)
        XCTAssertLessThan(bands.left[rightPeak], 0.1)
        XCTAssertTrue(analyzer.analyze(stereo: [], sampleRate: 48_000).left.isEmpty)
        let silent = analyzer.analyze(stereo: Array(repeating: 0, count: 4096), sampleRate: 48_000)
        XCTAssertTrue(silent.left.allSatisfy { $0 == 0 })
        XCTAssertTrue(silent.right.allSatisfy { $0 == 0 })
    }

    func testObservationRingDropsWhenFullAndWrapsWithoutChangingAudio() throws {
        let renderer = try XCTUnwrap(MCPPCMRendererCreate(2048, 2))
        defer { MCPPCMRendererDestroy(renderer) }
        MCPPCMRendererSetSignalMeteringEnabled(renderer, true)
        MCPPCMRendererSetPlaying(renderer, true)
        var observed = [Float](repeating: 0, count: 4096)
        for pass in 0..<12 {
            let value = Float(pass + 1) / 16
            let samples = (0..<2048).flatMap { _ in [value, -value] }
            samples.withUnsafeBufferPointer { XCTAssertEqual(MCPPCMRendererWrite(renderer, $0.baseAddress!, 2048), 2048) }
            var output = [Float](repeating: 0, count: 4096)
            output.withUnsafeMutableBytes { bytes in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                var flags: AudioUnitRenderActionFlags = []
                var timestamp = AudioTimeStamp()
                XCTAssertEqual(MCPPCMRenderCallback(UnsafeMutableRawPointer(renderer), &flags, &timestamp, 0, 2048, &buffers), noErr)
            }
            XCTAssertEqual(output, samples)
            // Fill the ring completely, deliberately overflow, then drain/wrap.
            if pass == 5 || pass > 5 {
                let copied = observed.withUnsafeMutableBufferPointer { MCPPCMRendererCopySpectrumWindow(renderer, $0.baseAddress!) }
                XCTAssertEqual(copied, 2048)
                let expected = pass == 5 ? Float(4) / 16 : value
                XCTAssertEqual(observed[0], expected)
                XCTAssertEqual(observed[1], -expected)
            }
        }
        MCPPCMRendererSetPlaying(renderer, false)
        observed.withUnsafeMutableBufferPointer { XCTAssertEqual(MCPPCMRendererCopySpectrumWindow(renderer, $0.baseAddress!), 0) }
    }
}
