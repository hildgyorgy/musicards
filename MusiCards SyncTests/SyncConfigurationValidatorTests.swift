import XCTest
@testable import MusiCards_Sync

final class SyncConfigurationValidatorTests: XCTestCase {
    private let validator = SyncConfigurationValidator(
        directoryExists: { _ in true }
    )

    func testAllowsSeparateLocalFolders() throws {
        XCTAssertNoThrow(
            try validator.validate(
                configuration(source: "/Volumes/Music", destination: "/Volumes/Backup")
            )
        )
    }

    func testRejectsSameLocalFolder() {
        XCTAssertThrowsError(
            try validator.validate(
                configuration(source: "/Volumes/Music", destination: "/Volumes/Music/")
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncConfigurationValidator.ValidationError,
                .sameSourceAndDestination
            )
        }
    }

    func testRejectsDestinationInsideSource() {
        XCTAssertThrowsError(
            try validator.validate(
                configuration(
                    source: "/Volumes/Music",
                    destination: "/Volumes/Music/Backup"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncConfigurationValidator.ValidationError,
                .destinationInsideSource
            )
        }
    }

    func testRejectsSourceInsideDestination() {
        XCTAssertThrowsError(
            try validator.validate(
                configuration(
                    source: "/Volumes/Backup/Music",
                    destination: "/Volumes/Backup"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncConfigurationValidator.ValidationError,
                .sourceInsideDestination
            )
        }
    }

    func testRemoteDestinationDoesNotUseLocalOverlapRules() throws {
        var configuration = SyncConfiguration.defaultConfiguration
        configuration.sourcePath = "/Music/"
        configuration.destination = .casaOSRPi4

        XCTAssertNoThrow(try validator.validate(configuration))
    }

    func testRejectsUnavailableLocalDestination() {
        let validator = SyncConfigurationValidator(
            directoryExists: { path in path != "/Volumes/Missing" }
        )

        XCTAssertThrowsError(
            try validator.validate(
                configuration(
                    source: "/Volumes/Source",
                    destination: "/Volumes/Missing"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncConfigurationValidator.ValidationError,
                .localDestinationUnavailable("/Volumes/Missing")
            )
        }
    }

    private func configuration(
        source: String,
        destination: String
    ) -> SyncConfiguration {
        SyncConfiguration(
            rsyncPath: "/opt/homebrew/bin/rsync",
            sourcePath: source,
            destination: DestinationProfile(
                name: "Local folder",
                kind: .local,
                path: destination
            ),
            sshKeyPath: "/tmp/key"
        )
    }
}
