import XCTest
@testable import MusiCards_Sync

final class RemoteDestinationStoreTests: XCTestCase {
    func testRoundTripPreservesUserCreatedRemoteProfile() {
        let suiteName = "MusiCardsSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RemoteDestinationStore(userDefaults: defaults)
        let profile = DestinationProfile(
            name: "Studio server",
            kind: .remote,
            user: "listener",
            host: "studio.local",
            port: 2_222,
            path: "/srv/music/"
        )

        store.save([profile])

        XCTAssertEqual(store.load(), [profile])
        XCTAssertEqual(store.load().first?.sshPort, 2_222)
    }

    func testLegacyProfileWithoutPortUsesStandardSSHPort() throws {
        let data = Data(#"[{"id":"11111111-1111-1111-1111-111111111111","name":"Server","kind":"remote","user":"music","host":"server.local","path":"/music/"}]"#.utf8)
        let profile = try JSONDecoder().decode(
            [DestinationProfile].self,
            from: data
        ).first

        XCTAssertEqual(profile?.sshPort, 22)
    }
}
