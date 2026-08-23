import XCTest
@testable import MusiCards_Sync

final class BundledRsyncTests: XCTestCase {
    func testBundledRsyncResolvesFromApplicationBundle() throws {
        let url = try XCTUnwrap(BundledRsync.executableURL())

        XCTAssertEqual(url.lastPathComponent, BundledRsync.executableName)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "MacOS")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
    }

    func testBundledRsyncVersionAndIconvCapability() throws {
        let info = try SyncEngine().rsyncVersionInfo()

        XCTAssertEqual(info.version, RsyncVersion(major: 3, minor: 5, patch: 0))
        XCTAssertTrue(info.supportsIconv)
    }

    func testDefaultConfigurationHasNoExternalRsyncPath() throws {
        let data = try JSONEncoder().encode(SyncConfiguration.defaultConfiguration)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("rsyncPath"))
        XCTAssertFalse(json.contains("/opt/homebrew"))
        XCTAssertFalse(json.contains("/usr/local"))
    }

    @MainActor
    func testLegacyRsyncPathIsRemovedWhenConfigurationLoads() throws {
        let suiteName = "MusiCardsSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "TestConfiguration"
        var expectedConfiguration = SyncConfiguration.defaultConfiguration
        expectedConfiguration.sourcePath = "/Volumes/Music/"
        expectedConfiguration.destination = DestinationProfile(
            name: "Backup",
            kind: .local,
            path: "/Volumes/Backup/"
        )
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(expectedConfiguration)
            ) as? [String: Any]
        )
        legacy["rsyncPath"] = "/opt/homebrew/bin/rsync"
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: key
        )

        let store = SyncConfigurationStore(userDefaults: defaults, key: key)
        XCTAssertEqual(store.load(), expectedConfiguration)

        let migratedData = try XCTUnwrap(defaults.data(forKey: key))
        let migrated = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertNil(migrated["rsyncPath"])
    }
}
