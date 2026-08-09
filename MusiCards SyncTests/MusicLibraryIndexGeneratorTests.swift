import XCTest
@testable import MusiCards_Sync

final class MusicLibraryIndexGeneratorTests: XCTestCase {
    func testEmptyLibraryCreatesStableManifest() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstSummary = try await LocalLibraryManifestGenerator.generate(
            in: rootURL,
            progress: { _ in }
        )
        XCTAssertTrue(firstSummary.indexWasUpdated)
        XCTAssertEqual(firstSummary.indexedAlbumCount, 0)
        XCTAssertEqual(firstSummary.indexedTrackCount, 0)

        let manifestURL = rootURL.appendingPathComponent(
            LocalLibraryManifestLoader.fileName
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        let albums = try JSONDecoder().decode(
            [LocalLibraryManifestAlbum].self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertTrue(albums.isEmpty)

        let secondSummary = try await LocalLibraryManifestGenerator.generate(
            in: rootURL,
            progress: { _ in }
        )
        XCTAssertFalse(secondSummary.indexWasUpdated)
    }
}
