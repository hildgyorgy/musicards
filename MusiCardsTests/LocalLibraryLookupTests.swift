import XCTest
@testable import MusiCards

final class LocalLibraryLookupTests: XCTestCase {
    func testHybridSACDOnlyMarksTheIndexedLayerPlayable() {
        let sacdFile = file(
            path: "Verse/SACD/01 The Moon.flac",
            releaseID: "release",
            recordingID: "shared-recording",
            releaseTrackID: "sacd-track"
        )
        let lookup = LocalLibraryLookup(files: [sacdFile])

        XCTAssertNotNil(
            lookup.audioFile(
                releaseID: "release",
                releaseTrackID: "sacd-track",
                recordingID: "shared-recording",
                allowsRecordingFallback: true
            )
        )
        XCTAssertNil(
            lookup.audioFile(
                releaseID: "release",
                releaseTrackID: "cd-track",
                recordingID: "shared-recording",
                allowsRecordingFallback: true
            )
        )
    }

    func testPartialAlbumOnlyMarksPresentTracksPlayable() {
        let lookup = LocalLibraryLookup(files: [
            file(
                path: "Album/02 Present.flac",
                releaseID: "release",
                recordingID: "recording-2",
                releaseTrackID: "track-2"
            )
        ])

        XCTAssertTrue(lookup.containsRelease("release"))
        XCTAssertTrue(
            lookup.containsTrack(
                releaseID: "release",
                releaseTrackID: "track-2",
                recordingID: "recording-2",
                allowsRecordingFallback: false
            )
        )
        XCTAssertFalse(
            lookup.containsTrack(
                releaseID: "release",
                releaseTrackID: "track-1",
                recordingID: "recording-1",
                allowsRecordingFallback: false
            )
        )
    }

    func testUniqueLegacyRecordingFallbackRemainsSupported() {
        let legacyFile = file(
            path: "Legacy/01 Song.flac",
            releaseID: "release",
            recordingID: "recording",
            releaseTrackID: nil
        )
        let lookup = LocalLibraryLookup(files: [legacyFile])

        XCTAssertNil(
            lookup.audioFile(
                releaseID: "release",
                releaseTrackID: "track",
                recordingID: "recording",
                allowsRecordingFallback: false
            )
        )
        XCTAssertEqual(
            lookup.audioFile(
                releaseID: "release",
                releaseTrackID: "track",
                recordingID: "recording",
                allowsRecordingFallback: true
            )?.relativePath,
            legacyFile.relativePath
        )
    }

    func testAmbiguousLegacyRecordingDoesNotGuess() {
        let lookup = LocalLibraryLookup(files: [
            file(
                path: "Disc 1/01 Song.flac",
                releaseID: "release",
                recordingID: "recording",
                releaseTrackID: nil
            ),
            file(
                path: "Disc 2/01 Song.flac",
                releaseID: "release",
                recordingID: "recording",
                releaseTrackID: nil
            )
        ])

        XCTAssertNil(
            lookup.audioFile(
                releaseID: "release",
                releaseTrackID: nil,
                recordingID: "recording",
                allowsRecordingFallback: true
            )
        )
    }

    func testArtistMatchingIsExactAfterNormalization() {
        let lookup = LocalLibraryLookup(files: [
            file(
                path: "Verse/01 Song.flac",
                artist: "Patrícia Barber",
                album: "Verse",
                releaseID: "release",
                recordingID: "recording",
                releaseTrackID: "track"
            )
        ])

        XCTAssertTrue(lookup.containsArtist(named: "Patricia Barber"))
        XCTAssertFalse(lookup.containsArtist(named: "Patricia"))
        XCTAssertFalse(lookup.containsArtist(named: "Barber"))
        XCTAssertTrue(
            lookup.containsReleaseGroup(
                title: "Verse",
                artistName: "Patricia Barber"
            )
        )
    }

    private func file(
        path: String,
        artist: String = "Artist",
        album: String = "Album",
        releaseID: String,
        recordingID: String?,
        releaseTrackID: String?
    ) -> LocalAudioFileSnapshot {
        LocalAudioFileSnapshot(
            id: path,
            rootID: "root",
            relativePath: path,
            title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            artist: artist,
            albumTitle: album,
            releaseMBID: releaseID,
            recordingMBID: recordingID,
            releaseTrackMBID: releaseTrackID
        )
    }
}
