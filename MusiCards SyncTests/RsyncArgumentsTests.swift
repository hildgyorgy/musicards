import XCTest
@testable import MusiCards_Sync

final class RsyncArgumentsTests: XCTestCase {
    func testRemoteDryRunArgumentsPreserveMirrorAndUnicodeSemantics() throws {
        let configuration = remoteConfiguration()
        let arguments = try SyncEngine.rsyncArguments(
            configuration: configuration,
            dryRun: true
        )

        XCTAssertTrue(arguments.contains("--dry-run"))
        XCTAssertTrue(arguments.contains("--delete"))
        XCTAssertTrue(arguments.contains("--delete-excluded"))
        XCTAssertTrue(arguments.contains("--iconv=UTF-8-MAC,UTF-8"))
        XCTAssertTrue(arguments.contains("--secluded-args"))
        XCTAssertTrue(arguments.contains("--timeout=30"))
        XCTAssertTrue(
            arguments.contains(where: {
                $0.contains("-p 2222")
            })
        )
        XCTAssertFalse(arguments.contains("--no-inc-recursive"))
        XCTAssertFalse(arguments.contains("--info=progress2"))
        XCTAssertTrue(arguments.contains("--filter=P /library.json"))
        XCTAssertTrue(arguments.contains("--exclude=/library.json"))
        XCTAssertEqual(Array(arguments.suffix(2)), [
            configuration.sourcePath,
            configuration.destination.remoteDestination
        ])
    }

    func testRealSyncEmitsCompletedFileRecords() throws {
        let arguments = try SyncEngine.rsyncArguments(
            configuration: remoteConfiguration(),
            dryRun: false
        )

        XCTAssertFalse(arguments.contains("--dry-run"))
        XCTAssertTrue(arguments.contains("--no-inc-recursive"))
        XCTAssertFalse(arguments.contains("--info=progress2"))
        XCTAssertTrue(arguments.contains("--out-format=%i|%n|%b"))
        XCTAssertTrue(arguments.contains("--outbuf=L"))
        XCTAssertTrue(arguments.contains("--filter=P /library.json"))
        XCTAssertTrue(arguments.contains("--exclude=/library.json"))
    }

    func testRemoteShellUsesSystemSSHAndQuotesKeyPathAsOneArgument() throws {
        let plain = try SSHInvocation.rsyncRemoteShell(
            keyPath: "/Users/test/.ssh/id_ed25519",
            port: 22
        )
        let spaced = try SSHInvocation.rsyncRemoteShell(
            keyPath: "/Users/test/SSH Keys/Music Server Key",
            port: 22
        )
        let punctuation = try SSHInvocation.rsyncRemoteShell(
            keyPath: "/Users/test/Keys/O'Reilly\\Key",
            port: 22
        )

        XCTAssertTrue(plain.hasPrefix("/usr/bin/ssh "))
        XCTAssertTrue(spaced.contains("'/Users/test/SSH Keys/Music Server Key'"))
        XCTAssertTrue(punctuation.contains("'/Users/test/Keys/O''Reilly\\Key'"))
        XCTAssertFalse(punctuation.contains("'\\''"))

        let configuration = remoteConfiguration()
        let arguments = try SyncEngine.rsyncArguments(configuration: configuration, dryRun: true)
        let shell = try XCTUnwrap(arguments.first { $0.contains("/usr/bin/ssh") })
        XCTAssertTrue(shell.contains("/usr/bin/ssh -i"))
    }

    func testMalformedRemoteIdentityCannotBecomeRsyncDestination() throws {
        let configuration = SyncConfiguration(
            sourcePath: "/Volumes/Source/",
            destination: DestinationProfile(
                name: "Untrusted",
                kind: .remote,
                user: "user;rm",
                host: "example.com;rm",
                path: "/srv/music/"
            ),
            sshKeyPath: "/tmp/key"
        )

        XCTAssertThrowsError(
            try SyncEngine.rsyncArguments(configuration: configuration, dryRun: true)
        ) { error in
            XCTAssertEqual(error as? SSHInvocation.ValidationError, .invalidUsername)
        }
    }

    func testLocalDestinationDoesNotAddSshArguments() throws {
        let configuration = SyncConfiguration(
            sourcePath: "/Volumes/Source/",
            destination: DestinationProfile(
                name: "Local folder",
                kind: .local,
                path: "/Volumes/Destination/"
            ),
            sshKeyPath: "/tmp/key"
        )
        let arguments = try SyncEngine.rsyncArguments(
            configuration: configuration,
            dryRun: true
        )

        XCTAssertFalse(arguments.contains("--timeout=30"))
        XCTAssertFalse(arguments.contains("-e"))
        XCTAssertEqual(arguments.last, "/Volumes/Destination/")
    }

    func testLocalMirrorProtectsPublishedManifest() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = testRoot.appendingPathComponent("source", isDirectory: true)
        let destination = testRoot.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: testRoot) }

        try Data("source index".utf8).write(
            to: source.appendingPathComponent("library.json")
        )
        try Data("published index".utf8).write(
            to: destination.appendingPathComponent("library.json")
        )
        try Data("music".utf8).write(
            to: source.appendingPathComponent("track.flac")
        )

        let configuration = SyncConfiguration(
            sourcePath: source.path + "/",
            destination: DestinationProfile(
                name: "Local folder",
                kind: .local,
                path: destination.path + "/"
            ),
            sshKeyPath: "/tmp/key"
        )
        let process = Process()
        process.executableURL = try XCTUnwrap(BundledRsync.executableURL())
        process.arguments = try SyncEngine.rsyncArguments(
            configuration: configuration,
            dryRun: false
        )
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("library.json")),
            Data("published index".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("track.flac")),
            Data("music".utf8)
        )
    }

    func testRemoteIndexPublicationTransfersOnlyManifest() throws {
        let configuration = remoteConfiguration()
        let arguments = try SyncEngine.libraryIndexPublishArguments(
            configuration: configuration
        )

        XCTAssertFalse(arguments.contains("--delete"))
        XCTAssertFalse(arguments.contains("--delete-excluded"))
        XCTAssertFalse(arguments.contains("--exclude=/library.json"))
        XCTAssertTrue(arguments.contains("--timeout=30"))
        XCTAssertTrue(arguments.contains("-e"))
        XCTAssertEqual(Array(arguments.suffix(2)), [
            "/Volumes/Source/library.json",
            configuration.destination.remoteDestination
        ])
    }

    func testRemoteIndexInvalidationDeletesOnlyManifest() throws {
        let configuration = remoteConfiguration()
        let arguments = try SyncEngine.libraryIndexInvalidationArguments(
            configuration: configuration,
            emptySourcePath: "/tmp/empty-index-source"
        )

        XCTAssertTrue(arguments.contains("--delete"))
        XCTAssertFalse(arguments.contains("--delete-excluded"))
        XCTAssertTrue(arguments.contains("--include=/library.json"))
        XCTAssertTrue(arguments.contains("--exclude=/*"))
        XCTAssertTrue(arguments.contains("--timeout=30"))
        XCTAssertTrue(arguments.contains("-e"))
        XCTAssertEqual(Array(arguments.suffix(2)), [
            "/tmp/empty-index-source/",
            configuration.destination.remoteDestination
        ])
    }

    func testLocalIndexInvalidationDoesNotAddSSHArguments() throws {
        let configuration = SyncConfiguration(
            sourcePath: "/Volumes/Source/",
            destination: DestinationProfile(
                name: "Local folder",
                kind: .local,
                path: "/Volumes/Destination/"
            ),
            sshKeyPath: "/tmp/key"
        )
        let arguments = try SyncEngine.libraryIndexInvalidationArguments(
            configuration: configuration,
            emptySourcePath: "/tmp/empty-index-source/"
        )

        XCTAssertFalse(arguments.contains("--timeout=30"))
        XCTAssertFalse(arguments.contains("-e"))
        XCTAssertEqual(Array(arguments.suffix(2)), [
            "/tmp/empty-index-source/",
            "/Volumes/Destination/"
        ])
    }

    func testLocalIndexInvalidationPreservesMusicAndDeletesManifest() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let emptySource = testRoot.appendingPathComponent(
            "empty",
            isDirectory: true
        )
        let destination = testRoot.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: emptySource,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: testRoot) }

        let manifestURL = destination.appendingPathComponent("library.json")
        let musicURL = destination.appendingPathComponent("track.flac")
        try Data("old index".utf8).write(to: manifestURL)
        try Data("music".utf8).write(to: musicURL)

        let configuration = SyncConfiguration(
            sourcePath: testRoot.path,
            destination: DestinationProfile(
                name: "Local folder",
                kind: .local,
                path: destination.path + "/"
            ),
            sshKeyPath: "/tmp/key"
        )
        let process = Process()
        process.executableURL = try XCTUnwrap(BundledRsync.executableURL())
        process.arguments = try SyncEngine.libraryIndexInvalidationArguments(
            configuration: configuration,
            emptySourcePath: emptySource.path
        )
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: musicURL.path))
    }

    func testLocalIndexPublicationDoesNotAddSSHArguments() throws {
        let configuration = SyncConfiguration(
            sourcePath: "/Volumes/Source/",
            destination: DestinationProfile(
                name: "Local folder",
                kind: .local,
                path: "/Volumes/Destination/"
            ),
            sshKeyPath: "/tmp/key"
        )
        let arguments = try SyncEngine.libraryIndexPublishArguments(
            configuration: configuration
        )

        XCTAssertFalse(arguments.contains("--timeout=30"))
        XCTAssertFalse(arguments.contains("-e"))
        XCTAssertEqual(Array(arguments.suffix(2)), [
            "/Volumes/Source/library.json",
            "/Volumes/Destination/"
        ])
    }

    private func remoteConfiguration() -> SyncConfiguration {
        SyncConfiguration(
            sourcePath: "/Volumes/Source/",
            destination: DestinationProfile(
                name: "Test server",
                kind: .remote,
                user: "music",
                host: "server.local",
                port: 2_222,
                path: "/srv/music/"
            ),
            sshKeyPath: "/Users/test/.ssh/musicards_sync"
        )
    }
}
