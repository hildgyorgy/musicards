import XCTest
@testable import MusiCards_Sync

final class RsyncOutputStateTests: XCTestCase {
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
