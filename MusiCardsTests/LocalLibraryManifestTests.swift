import XCTest
@testable import MusiCards

final class LocalLibraryManifestTests: XCTestCase {
    func testDecodesCurrentManifestAndPreservesTrackIdentity() throws {
        let data = Data(
            """
            [{
              "index_version": \(LocalLibraryManifestGenerator.currentIndexVersion),
              "library_album_count": 916,
              "album_name": "Verse",
              "artist_name": "Patricia Barber",
              "album_mbid": "release-id",
              "release_year": "2002",
              "country": "US",
              "label": "Blue Note",
              "media_format": "Hybrid SACD",
              "folder_path": "Patricia Barber/Verse",
              "tracks": [{
                "filename": "01 The Moon.flac",
                "title": "The Moon",
                "track_mbid": "recording-id",
                "release_track_mbid": "sacd-track-id",
                "codec": "FLAC",
                "bit_depth": 24,
                "sample_rate": 88200,
                "bitrate": 2512000,
                "channels": 2,
                "file_size": 123456,
                "modified_at": "2026-08-13T08:00:00Z"
              }]
            }]
            """.utf8
        )

        let snapshot = try LocalLibraryManifestLoader.decode(data)

        XCTAssertEqual(snapshot.identifiedAlbumCount, 1)
        XCTAssertEqual(snapshot.totalAlbumCount, 916)
        XCTAssertEqual(snapshot.files.count, 1)
        let file = try XCTUnwrap(snapshot.files.first)
        XCTAssertEqual(file.relativePath, "Patricia Barber/Verse/01 The Moon.flac")
        XCTAssertEqual(file.releaseMBID, "release-id")
        XCTAssertEqual(file.recordingMBID, "recording-id")
        XCTAssertEqual(file.releaseTrackMBID, "sacd-track-id")
        XCTAssertEqual(file.codec, "FLAC")
        XCTAssertEqual(file.bitDepth, 24)
        XCTAssertEqual(file.sampleRate, 88_200)
        XCTAssertEqual(file.channelCount, 2)
    }

    func testDecodesLegacyManifestWithSafeDefaults() throws {
        let data = Data(
            """
            [{
              "album_mbid": "release-id",
              "folder_path": ".",
              "tracks": [{"filename": "song.m4a"}]
            }]
            """.utf8
        )

        let snapshot = try LocalLibraryManifestLoader.decode(data)
        let file = try XCTUnwrap(snapshot.files.first)

        XCTAssertNil(snapshot.totalAlbumCount)
        XCTAssertEqual(file.relativePath, "song.m4a")
        XCTAssertEqual(file.title, "song")
        XCTAssertEqual(file.codec, "M4A")
        XCTAssertEqual(file.sampleRate, 0)
        XCTAssertEqual(file.channelCount, 0)
    }

    func testRejectsPathTraversal() {
        let data = Data(
            """
            [{
              "album_mbid": "release-id",
              "folder_path": "../Outside",
              "tracks": [{"filename": "song.flac"}]
            }]
            """.utf8
        )

        XCTAssertThrowsError(try LocalLibraryManifestLoader.decode(data))
    }

    func testPythonAndSwiftIndexVersionsStayInSync() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pythonToolURL = projectRoot
            .appendingPathComponent("Tools/generate_library.py")
        let source = try String(contentsOf: pythonToolURL, encoding: .utf8)
        let declaration = try NSRegularExpression(
            pattern: #"(?m)^\s*INDEX_VERSION\s*=\s*(\d+)\s*(?:#.*)?$"#
        )
        let sourceRange = NSRange(source.startIndex..., in: source)
        let matches = declaration.matches(in: source, range: sourceRange)

        XCTAssertEqual(
            matches.count,
            1,
            "Tools/generate_library.py must declare exactly one integer INDEX_VERSION."
        )
        let match = try XCTUnwrap(matches.first)
        let versionRange = try XCTUnwrap(
            Range(match.range(at: 1), in: source)
        )
        let pythonVersion = try XCTUnwrap(Int(source[versionRange]))

        XCTAssertEqual(
            pythonVersion,
            LocalLibraryManifestGenerator.currentIndexVersion,
            "The Swift index generator and Tools/generate_library.py must update INDEX_VERSION together."
        )
    }
}
