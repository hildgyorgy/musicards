import XCTest
@testable import MusiCards_Sync

final class SyncEnginePreviewTests: XCTestCase {

    func testBundledRsyncPreservesUnicodeInPreviewAndCopiedFiles() async throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = fixture.appendingPathComponent("source")
        let destination = fixture.appendingPathComponent("destination")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let name = "Árvíztűrő ősz.flac"
        let contents = Data("fixture".utf8)
        try contents.write(to: source.appendingPathComponent(name))
        let engine = SyncEngine(configuration: SyncConfiguration(
            sourcePath: source.path + "/",
            destination: DestinationProfile(name: "Disposable test", kind: .local, path: destination.path + "/"),
            sshKeyPath: "/unused"
        ))
        let preview = engine.parsePreview(try await engine.preview())
        XCTAssertEqual(preview.newFiles, [name])
        try await engine.sync()
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), contents)
    }

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

    func testOnlineOnlyDetectorCountsOnlyDatalessModifiedFiles() {
        let detector = OnlineOnlyFileDetector { path in
            switch path {
            case "/source/online.m4a":
                return OnlineOnlyFileMetadata(
                    isRegularFile: true,
                    isDataless: true
                )
            case "/source/local.m4a":
                return OnlineOnlyFileMetadata(
                    isRegularFile: true,
                    isDataless: false
                )
            default:
                return nil
            }
        }

        XCTAssertEqual(
            detector.countOnlineOnlyFiles(
                modifiedPaths: ["online.m4a", "local.m4a", "missing.m4a"],
                sourceDirectory: "/source"
            ),
            1
        )
    }

    func testOnlineOnlyDetectorDoesNotInferDatalessFromAllocationAlone() {
        let detector = OnlineOnlyFileDetector { _ in
            OnlineOnlyFileMetadata(isRegularFile: true, isDataless: false)
        }

        XCTAssertFalse(detector.isOnlineOnly(path: "/source/sparse.m4a"))
    }

    func testOnlineOnlyDetectorHandlesNoModifiedFiles() {
        let detector = OnlineOnlyFileDetector { _ in
            XCTFail("No metadata lookup should be needed")
            return nil
        }

        XCTAssertEqual(
            detector.countOnlineOnlyFiles(
                modifiedPaths: [],
                sourceDirectory: "/source"
            ),
            0
        )
    }
}
