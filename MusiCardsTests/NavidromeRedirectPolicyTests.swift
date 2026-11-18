import Foundation
import Network
import XCTest
@testable import MusiCards

final class NavidromeRedirectPolicyTests: XCTestCase {
    func testAllowsOnlySameOriginWithoutURLCredentials() {
        let original = URL(string: "https://music.example/rest/ping")!
        for target in ["https://music.example/rest/ping/", "https://MUSIC.example:443/other"] {
            XCTAssertTrue(NavidromeRedirectPolicy.allowsRedirect(from: original, to: URL(string: target)))
        }
        for target in ["http://music.example/rest/ping", "https://other.example/", "https://music.example:8443/",
                       "https://user:password@music.example/", "file:///tmp/music"] {
            XCTAssertFalse(NavidromeRedirectPolicy.allowsRedirect(from: original, to: URL(string: target)), target)
        }
        XCTAssertFalse(NavidromeRedirectPolicy.allowsRedirect(from: nil, to: original))
    }

    func testAPIAndRangeRequestsRejectCrossOrigin307And308() async throws {
        for status in [307, 308] {
            let listener = try NWListener(using: .tcp, on: .any)
            let ready = expectation(description: "redirect server ready")
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.fulfill() }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    // A different port is a different origin. No listener is
                    // needed there: following this redirect would fail the test.
                    let reply = "HTTP/1.1 \(status) Redirect\r\nLocation: http://127.0.0.1:1/leaked\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: .global())
            defer { listener.cancel() }
            await fulfillment(of: [ready], timeout: 3)
            let port = try XCTUnwrap(listener.port)
            let baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)")!
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let client = OpenSubsonicClient(session: session)
            do {
                _ = try await client.identifyNavidrome(
                    profile: NavidromeServerProfile(name: "Test", baseURL: baseURL, username: "listener"),
                    password: "test-only", allowsInsecureLocalHTTP: true
                )
                XCTFail("Expected rejected redirect")
            } catch {
                guard case NavidromeConnectionError.httpStatus(let received) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(received, status)
            }
            var request = URLRequest(url: baseURL.appendingPathComponent("stream"))
            request.httpMethod = "POST"
            request.httpBody = Data("u=test&t=test&s=test".utf8)
            let result = try await URLSessionHTTPRangeLoader(session: session).load(request: request, start: 0, end: 3)
            XCTAssertEqual(result.statusCode, status)
            XCTAssertTrue(result.data.isEmpty)
        }
    }
}
