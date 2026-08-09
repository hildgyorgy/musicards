import XCTest
@testable import MusiCards_Sync

final class SyncEnginePreviewTests: XCTestCase {

    func testParsePreviewClassifiesRsyncChanges() {
        let output = """
        >f+++++++++|album/new-track.m4a
        <f.s.......|album/modified-track.m4a
        cd+++++++++|album/new-folder/
        *deleting|album/old-track.m4a
        *deleting|album/old-folder/
        *deleting|album/.DS_Store
        *deleting|album/._cover.jpg
        """

        let preview = SyncEngine().parsePreview(output)

        XCTAssertEqual(preview.newFiles, ["album/new-track.m4a"])
        XCTAssertEqual(preview.modifiedFiles, ["album/modified-track.m4a"])
        XCTAssertEqual(preview.newFolders, ["album/new-folder/"])
        XCTAssertEqual(preview.deletedFiles, ["album/old-track.m4a"])
        XCTAssertEqual(preview.deletedFolders, ["album/old-folder/"])
        XCTAssertEqual(
            preview.systemCleanup,
            ["album/.DS_Store", "album/._cover.jpg"]
        )
        XCTAssertEqual(preview.affectedFileCount, 5)
    }

    func testParsePreviewReportsNoChangesForSummaryOutput() {
        let output = """
        sent 128 bytes  received 64 bytes
        total size is 0  speedup is 0.00 (DRY RUN)
        """

        let preview = SyncEngine().parsePreview(output)

        XCTAssertFalse(preview.hasChanges)
    }
}
