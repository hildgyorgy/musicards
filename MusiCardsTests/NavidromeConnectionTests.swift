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

    func testPingRequestRejectsInsecureHTTP() {
        XCTAssertThrowsError(
            try pingRequest(baseURL: URL(string: "http://music.example.com")!)
        ) { error in
            XCTAssertEqual(error as? NavidromeConnectionError, .secureConnectionRequired)
        }
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
