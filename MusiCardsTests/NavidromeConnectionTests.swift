import Foundation
import XCTest
@testable import MusiCards

final class NavidromeConnectionTests: XCTestCase {
    private func pingRequest(
        baseURL: URL,
        username: String = "listener",
        password: String = "password",
        salt: String = "abcdef"
    ) throws -> URLRequest {
        let profile = NavidromeServerProfile(
            name: "Test Server",
            baseURL: baseURL,
            username: username
        )

        return try OpenSubsonicRequestBuilder().pingRequest(
            profile: profile,
            password: password,
            salt: salt
        )
    }

    private func verify(_ data: Data) throws -> NavidromeServerIdentity {
        let envelope = try JSONDecoder().decode(OpenSubsonicPingEnvelope.self, from: data)
        return try NavidromeServerVerifier.identity(from: envelope.response)
    }

    func testSaltedTokenMatchesKnownVector() throws {
        let token = OpenSubsonicAuthentication.token(
            password: "sesame",
            salt: "c19b2d"
        )

        XCTAssertEqual(token, "26719a1196d2a940705a59634eb18eab")
    }

    func testPingRequestUsesHTTPSPostAndDoesNotExposePassword() throws {
        let request = try pingRequest(
            baseURL: URL(string: "https://music.example.com")!,
            password: "super secret",
            salt: "abcdef"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://music.example.com/rest/ping")
        XCTAssertNil(request.url?.query)

        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("u=listener"))
        XCTAssertTrue(body.contains("s=abcdef"))
        XCTAssertTrue(body.contains("t="))
        XCTAssertTrue(body.contains("v=1.16.1"))
        XCTAssertTrue(body.contains("c=MusiCards"))
        XCTAssertTrue(body.contains("f=json"))
        XCTAssertFalse(body.contains("super"))
        XCTAssertFalse(body.contains("secret"))
        XCTAssertFalse(body.contains("p="))
    }

    func testPingRequestPreservesServerPathPrefix() throws {
        let request = try pingRequest(
            baseURL: URL(string: "https://music.example.com/navidrome")!
        )

        XCTAssertEqual(request.url?.path, "/navidrome/rest/ping")
    }

    func testPingRequestDoesNotDuplicateRestPath() throws {
        let request = try pingRequest(
            baseURL: URL(string: "https://music.example.com/navidrome/rest/")!
        )

        XCTAssertEqual(request.url?.path, "/navidrome/rest/ping")
    }

    func testAlbumListRequestUsesAlphabeticalPagination() throws {
        let profile = NavidromeServerProfile(
            name: "Test Server",
            baseURL: URL(string: "https://music.example.com/navidrome")!,
            username: "listener"
        )
        let request = try OpenSubsonicRequestBuilder().albumListRequest(
            profile: profile,
            password: "password",
            salt: "abcdef",
            offset: 500,
            size: 500
        )

        XCTAssertEqual(
            request.url?.path,
            "/navidrome/rest/getAlbumList2"
        )
        let body = try XCTUnwrap(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        )
        XCTAssertTrue(body.contains("type=alphabeticalByName"))
        XCTAssertTrue(body.contains("offset=500"))
        XCTAssertTrue(body.contains("size=500"))
    }

    func testAlbumDetailRequestUsesServerAlbumID() throws {
        let profile = NavidromeServerProfile(
            name: "Test Server",
            baseURL: URL(string: "https://music.example.com")!,
            username: "listener"
        )
        let request = try OpenSubsonicRequestBuilder().albumRequest(
            profile: profile,
            password: "password",
            salt: "abcdef",
            albumID: "album/id"
        )

        XCTAssertEqual(request.url?.path, "/rest/getAlbum")
        let body = try XCTUnwrap(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        )
        XCTAssertTrue(body.contains("id=album%2Fid"))
    }

    func testRawStreamRequestUsesSongIDWithoutTranscodingParameters() throws {
        let profile = NavidromeServerProfile(
            name: "Test Server",
            baseURL: URL(string: "http://music.example.com/navidrome")!,
            username: "listener"
        )
        let request = try OpenSubsonicRequestBuilder().streamRequest(
            profile: profile,
            password: "super secret",
            salt: "abcdef",
            songID: "song/id"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/navidrome/rest/stream")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "audio/*, application/octet-stream"
        )

        let body = try XCTUnwrap(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        )
        XCTAssertTrue(body.contains("id=song%2Fid"))
        XCTAssertTrue(body.contains("format=raw"))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("bitrate"))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("transcod"))
        XCTAssertFalse(body.contains("super"))
        XCTAssertFalse(body.contains("secret"))
        XCTAssertFalse(body.contains("p="))
    }

    func testAlbumResponsesDecodeReleaseMusicBrainzID() throws {
        let data = Data(
            """
            {
              "subsonic-response": {
                "status": "ok",
                "albumList2": {
                  "album": [{
                    "id": "album-1",
                    "name": "Release",
                    "artist": "Artist 1 feat. Artist 2",
                    "artists": [{
                      "id": "artist-1",
                      "name": "Artist 1"
                    }, {
                      "id": "artist-2",
                      "name": "Artist 2"
                    }],
                    "musicBrainzId": "189002e7-3285-4e2e-92a3-7f6c30d407a2"
                  }]
                }
              }
            }
            """.utf8
        )

        let envelope = try JSONDecoder().decode(
            OpenSubsonicAlbumListEnvelope.self,
            from: data
        )

        XCTAssertEqual(
            envelope.response.albumList?.albums.first?.musicBrainzID,
            "189002e7-3285-4e2e-92a3-7f6c30d407a2"
        )
        XCTAssertEqual(
            envelope.response.albumList?.albums.first?.artist,
            "Artist 1 feat. Artist 2"
        )
        XCTAssertEqual(
            envelope.response.albumList?.albums.first?.artists.map(\.name),
            ["Artist 1", "Artist 2"]
        )
    }

    func testAlbumDetailDecodesSongRecordingMusicBrainzIDs() throws {
        let data = Data(
            """
            {
              "subsonic-response": {
                "status": "ok",
                "album": {
                  "id": "album-1",
                  "name": "Release",
                  "musicBrainzId": "189002e7-3285-4e2e-92a3-7f6c30d407a2",
                  "song": [{
                    "id": "song-1",
                    "musicBrainzId": "bf99cae5-3b83-437a-a266-7126bd5653bf",
                    "title": "Hi-Res Track",
                    "suffix": "flac",
                    "contentType": "audio/flac",
                    "size": 123456789,
                    "duration": 321,
                    "bitRate": 4512,
                    "samplingRate": 96000,
                    "bitDepth": 24,
                    "channelCount": 2
                  }]
                }
              }
            }
            """.utf8
        )

        let envelope = try JSONDecoder().decode(
            OpenSubsonicAlbumEnvelope.self,
            from: data
        )

        XCTAssertEqual(
            envelope.response.album?.songs.first?.musicBrainzID,
            "bf99cae5-3b83-437a-a266-7126bd5653bf"
        )
        let song = try XCTUnwrap(envelope.response.album?.songs.first)
        XCTAssertEqual(song.title, "Hi-Res Track")
        XCTAssertEqual(song.suffix, "flac")
        XCTAssertEqual(song.contentType, "audio/flac")
        XCTAssertEqual(song.size, 123_456_789)
        XCTAssertEqual(song.duration, 321)
        XCTAssertEqual(song.bitRate, 4_512)
        XCTAssertEqual(song.samplingRate, 96_000)
        XCTAssertEqual(song.bitDepth, 24)
        XCTAssertEqual(song.channelCount, 2)
    }

    func testAuthenticatedRequestsSupportHTTP() throws {
        let request = try pingRequest(
            baseURL: URL(string: "http://music.example.com")!
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "http://music.example.com/rest/ping"
        )
    }

    func testVerifierAcceptsModernNavidromeResponse() throws {
        let data = Data(
            """
            {
              "subsonic-response": {
                "status": "ok",
                "version": "1.16.1",
                "type": "navidrome",
                "serverVersion": "0.58.0",
                "openSubsonic": true
              }
            }
            """.utf8
        )

        let identity = try verify(data)

        XCTAssertEqual(identity.serverVersion, "0.58.0")
        XCTAssertEqual(identity.protocolVersion, "1.16.1")
    }

    func testVerifierRequiresOpenSubsonic() {
        let data = Data(
            """
            {
              "subsonic-response": {
                "status": "ok",
                "version": "1.16.1",
                "type": "navidrome"
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(try verify(data)) { error in
            XCTAssertEqual(error as? NavidromeConnectionError, .openSubsonicRequired)
        }
    }

    func testVerifierRejectsNonNavidromeServer() {
        let data = Data(
            """
            {
              "subsonic-response": {
                "status": "ok",
                "version": "1.16.1",
                "type": "another-server",
                "openSubsonic": true
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(try verify(data)) { error in
            XCTAssertEqual(
                error as? NavidromeConnectionError,
                .notNavidrome(serverType: "another-server")
            )
        }
    }

    func testVerifierSurfacesServerRejection() {
        let data = Data(
            """
            {
              "subsonic-response": {
                "status": "failed",
                "version": "1.16.1",
                "error": {
                  "code": 40,
                  "message": "Wrong username or password"
                }
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(try verify(data)) { error in
            XCTAssertEqual(
                error as? NavidromeConnectionError,
                .serverRejected(code: 40, message: "Wrong username or password")
            )
        }
    }

    func testPersistedProfileContainsNoPassword() throws {
        let profile = NavidromeServerProfile(
            name: "Home",
            baseURL: URL(string: "https://music.example.com")!,
            username: "listener"
        )

        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
    }
}
