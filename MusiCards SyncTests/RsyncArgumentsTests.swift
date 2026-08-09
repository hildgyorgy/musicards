import XCTest
@testable import MusiCards_Sync

final class RsyncArgumentsTests: XCTestCase {
    func testRemoteDryRunArgumentsPreserveMirrorAndUnicodeSemantics() {
        let configuration = remoteConfiguration()
        let arguments = SyncEngine.rsyncArguments(
            configuration: configuration,
            dryRun: true
        )

        XCTAssertTrue(arguments.contains("--dry-run"))
        XCTAssertTrue(arguments.contains("--delete"))
        XCTAssertTrue(arguments.contains("--delete-excluded"))
        XCTAssertTrue(arguments.contains("--iconv=UTF-8-MAC,UTF-8"))
        XCTAssertTrue(arguments.contains("--secluded-args"))
        XCTAssertTrue(arguments.contains("--timeout=30"))
        XCTAssertFalse(arguments.contains("--no-inc-recursive"))
        XCTAssertFalse(arguments.contains("--info=progress2"))
        XCTAssertEqual(Array(arguments.suffix(2)), [
            configuration.sourcePath,
            configuration.destination.remoteDestination
        ])
    }

    func testRealSyncEmitsCompletedFileRecords() {
        let arguments = SyncEngine.rsyncArguments(
            configuration: remoteConfiguration(),
            dryRun: false
        )

        XCTAssertFalse(arguments.contains("--dry-run"))
        XCTAssertTrue(arguments.contains("--no-inc-recursive"))
        XCTAssertFalse(arguments.contains("--info=progress2"))
        XCTAssertTrue(arguments.contains("--out-format=%i|%n|%b"))
        XCTAssertTrue(arguments.contains("--outbuf=L"))
    }

    func testLocalDestinationDoesNotAddSshArguments() {
        let configuration = SyncConfiguration(
            rsyncPath: "/opt/homebrew/bin/rsync",
            sourcePath: "/Volumes/Source/",
            destination: DestinationProfile(
                name: "Local folder",
                kind: .local,
                path: "/Volumes/Destination/"
            ),
            sshKeyPath: "/tmp/key"
        )
        let arguments = SyncEngine.rsyncArguments(
            configuration: configuration,
            dryRun: true
        )

        XCTAssertFalse(arguments.contains("--timeout=30"))
        XCTAssertFalse(arguments.contains("-e"))
        XCTAssertEqual(arguments.last, "/Volumes/Destination/")
    }

    private func remoteConfiguration() -> SyncConfiguration {
        SyncConfiguration(
            rsyncPath: "/opt/homebrew/bin/rsync",
            sourcePath: "/Volumes/Source/",
            destination: .casaOSRPi4,
            sshKeyPath: "/Users/test/.ssh/musicards_sync"
        )
    }
}
