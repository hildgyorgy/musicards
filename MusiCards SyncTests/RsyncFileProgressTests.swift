import XCTest
@testable import MusiCards_Sync

final class RsyncFileProgressTests: XCTestCase {
    private let parser = RsyncCompletedItemParser()

    func testParsesCompletedFileAndRemovesInternalByteField() {
        XCTAssertEqual(
            parser.parse(">f+++++++++|album/track.m4a|12345"),
            RsyncCompletedItemRecord(
                path: "album/track.m4a",
                displayLine: ">f+++++++++|album/track.m4a"
            )
        )
    }

    func testParserPreservesPipeCharactersInsidePath() {
        XCTAssertEqual(
            parser.parse(">f+++++++++|album/a|b.m4a|987"),
            RsyncCompletedItemRecord(
                path: "album/a|b.m4a",
                displayLine: ">f+++++++++|album/a|b.m4a"
            )
        )
    }

    func testParserRejectsPreviewAndInvalidByteSuffix() {
        XCTAssertNil(parser.parse(">f+++++++++|album/track.m4a"))
        XCTAssertNil(parser.parse(">f+++++++++|album/track.m4a|unknown"))
    }

    func testTrackerBuildsCompletedAndPlannedSummaries() {
        var preview = SyncPreview()
        preview.newFiles = ["new.m4a"]
        preview.modifiedFiles = ["modified.m4a"]
        preview.newFolders = ["new-album/"]
        preview.deletedFiles = ["old.m4a"]
        preview.deletedFolders = ["old-album/"]
        preview.systemCleanup = ["._cover.jpg"]

        var tracker = RsyncProgressTracker(preview: preview)

        XCTAssertTrue(tracker.recordCompletion(for: "new.m4a"))
        XCTAssertTrue(tracker.recordCompletion(for: "new-album/"))
        XCTAssertTrue(tracker.recordCompletion(for: "._cover.jpg"))
        XCTAssertFalse(tracker.recordCompletion(for: "new.m4a"))
        XCTAssertFalse(tracker.recordCompletion(for: "unplanned.m4a"))
        XCTAssertEqual(tracker.completedCount, 2)
        XCTAssertEqual(tracker.totalCount, 4)
        XCTAssertEqual(tracker.progress, 0.5)
        XCTAssertEqual(
            tracker.completedSummary,
            SyncSummary(
                newFiles: 1,
                modifiedFiles: 0,
                newFolders: 1,
                deletedFiles: 0,
                deletedFolders: 0,
                systemCleanup: 1
            )
        )
        XCTAssertEqual(tracker.plannedSummary, SyncSummary(preview: preview))

        tracker.markAllCompleted()
        XCTAssertEqual(tracker.completedCount, 4)
        XCTAssertEqual(tracker.progress, 1)
        XCTAssertEqual(tracker.completedSummary, tracker.plannedSummary)
    }
}
