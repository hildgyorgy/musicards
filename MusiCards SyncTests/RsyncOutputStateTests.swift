import XCTest
@testable import MusiCards_Sync

final class RsyncOutputStateTests: XCTestCase {
    func testUTF8SurvivesEveryPossiblePipeBoundary() {
        let text = "ősz/árvíztűrő 🥁.flac\r\nsecond/é.flac\nlast/ű.flac"
        let bytes = Array(text.utf8)
        for split in 0...bytes.count {
            let state = RsyncOutputState()
            let lines = state.append(Data(bytes[..<split])) + state.append(Data(bytes[split...]))
            let result = state.finish()
            XCTAssertEqual(lines, ["ősz/árvíztűrő 🥁.flac", "second/é.flac"], "split \(split)")
            XCTAssertEqual(result.finalLine, "last/ű.flac")
            XCTAssertEqual(result.output, text)
            XCTAssertEqual(result.recentOutput, text)
        }
    }

    func testUTF8SurvivesOneByteAtATime() {
        let state = RsyncOutputState(capturesCompleteOutput: false)
        var lines: [String] = []
        for byte in "Árvíztűrő/🎵.flac\r\n".utf8 {
            lines += state.append(Data([byte]))
        }
        XCTAssertEqual(lines, ["Árvíztűrő/🎵.flac"])
        let result = state.finish()
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertNil(result.finalLine)
        XCTAssertEqual(result.recentOutput, "Árvíztűrő/🎵.flac\r\n")
    }

    func testCarriageReturnsEmitProgressUpdates() {
        let state = RsyncOutputState()

        XCTAssertEqual(
            state.append("0%\r25%\r100%\n"),
            ["0%", "25%", "100%"]
        )
        XCTAssertNil(state.finish().finalLine)
    }

    func testSplitCRLFDoesNotEmitAnEmptyLine() {
        let state = RsyncOutputState()

        XCTAssertEqual(state.append("first\r"), ["first"])
        XCTAssertEqual(state.append("\nsecond\n"), ["second"])
        XCTAssertNil(state.finish().finalLine)
    }

    func testFinishReturnsAnUnterminatedFinalLine() {
        let state = RsyncOutputState()

        XCTAssertTrue(state.append("partial").isEmpty)
        XCTAssertEqual(state.finish().finalLine, "partial")
    }

    func testSyncModeKeepsOnlyRecentErrorOutput() {
        let state = RsyncOutputState(capturesCompleteOutput: false)

        XCTAssertEqual(state.append("album/track.m4a\n"), ["album/track.m4a"])

        let result = state.finish()
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertTrue(result.recentOutput.contains("album/track.m4a"))
    }
}
