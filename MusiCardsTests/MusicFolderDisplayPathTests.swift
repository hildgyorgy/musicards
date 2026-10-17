import Foundation
import XCTest
@testable import MusiCards

final class MusicFolderDisplayPathTests: XCTestCase {
    func testIPhoneCloudStoragePathStartsWithProvider() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/CloudStorage/Dropbox/Music/Jazz")

        XCTAssertEqual(MusicFolderDisplayPath.label(for: url), "Dropbox/Music/Jazz")
    }

    func testIPhoneCloudStoragePathHidesProviderDomainUUID() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/CloudStorage/6D353D47-A722-420B-AD26-E3183D59DC7E/Gyorgy Hild/Music")

        XCTAssertEqual(MusicFolderDisplayPath.label(for: url), "Cloud storage/Gyorgy Hild/Music")
    }

    func testCloudStorageDomainRootDoesNotShowUUID() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/CloudStorage/6D353D47-A722-420B-AD26-E3183D59DC7E")

        XCTAssertEqual(MusicFolderDisplayPath.label(for: url), "Cloud storage")
    }

    func testMacCloudStoragePathStartsWithProvider() {
        let url = URL(fileURLWithPath: "/Users/example/Library/CloudStorage/OneDrive/Music")

        XCTAssertEqual(MusicFolderDisplayPath.label(for: url), "OneDrive/Music")
    }

    func testExternalSSDUsesVolumeNameAndRelativeFolder() {
        let volume = URL(fileURLWithPath: "/Volumes/MUSIC_1TB")
        let folder = volume.appendingPathComponent("Music/Jazz")

        XCTAssertEqual(
            MusicFolderDisplayPath.label(
                for: folder,
                volumeURL: volume,
                volumeName: "MUSIC_1TB",
                isExternalVolume: true
            ),
            "MUSIC_1TB/Music/Jazz"
        )
    }

    func testExternalSSDWithoutVolumeMetadataKeepsLastTwoNames() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/6D353D47-A722-420B-AD26-E3183D59DC7E/MUSIC_1TB/Music")

        XCTAssertEqual(
            MusicFolderDisplayPath.label(
                for: url,
                volumeURL: nil,
                volumeName: nil,
                isExternalVolume: false
            ),
            "MUSIC_1TB/Music"
        )
    }

    func testSystemVolumeNameDoesNotLeakInternalPath() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/Documents/Music")

        XCTAssertEqual(
            MusicFolderDisplayPath.label(
                for: url,
                volumeURL: URL(fileURLWithPath: "/"),
                volumeName: "Data",
                isExternalVolume: false
            ),
            "Documents/Music"
        )
    }

    func testICloudDrivePathUsesUserVisibleName() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Music")

        XCTAssertEqual(MusicFolderDisplayPath.label(for: url), "iCloud Drive/Music")
    }

    func testCloudStorageWithoutSelectedSubfolderShowsGenericLabel() {
        let url = URL(fileURLWithPath: "/Users/example/Library/CloudStorage")

        XCTAssertEqual(MusicFolderDisplayPath.label(for: url), "Cloud storage")
    }
}
