import Foundation
import XCTest
@testable import MusiCards

final class RendererPlaylistHTTPServerTests: XCTestCase {
    func testExactDIDLHeadersAndCompleteGETThenListenerCloses() async throws {
        let server = RendererPlaylistHTTPServer()
        let payload = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><DIDL-Lite/>".utf8)
        let url = try await server.start(document: payload, rendererURL: URL(string: "http://127.0.0.1/device.xml")!)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        let (empty, response) = try await session.data(for: head)
        XCTAssertTrue(empty.isEmpty)
        let headers = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(headers.value(forHTTPHeaderField: "Content-Type"), "text/xml")
        XCTAssertEqual(headers.value(forHTTPHeaderField: "contentFeatures.dlna.org"), "DLNA.ORG_PN=DIDL_S")
        XCTAssertEqual(headers.value(forHTTPHeaderField: "Content-Length"), String(payload.count))
        let (body, _) = try await session.data(from: url)
        XCTAssertEqual(body, payload)
        let downloaded = await server.finish()
        XCTAssertTrue(downloaded)
        var closed = URLRequest(url: url)
        closed.timeoutInterval = 1
        do { _ = try await session.data(for: closed); XCTFail("Listener must be closed") }
        catch { /* Expected connection failure. */ }
    }

    func testUnrecognizedPathCannotReadThePlaylist() async throws {
        let server = RendererPlaylistHTTPServer()
        let url = try await server.start(document: Data("private playlist".utf8), rendererURL: URL(string: "http://127.0.0.1/device.xml")!)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(from: url.appendingPathComponent("wrong"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(body.isEmpty)
        let downloaded = await server.finish()
        XCTAssertFalse(downloaded)
    }

    func testProtocolAdvertisementMustExplicitlySupportHTTPStaticDIDL() {
        for value in ["http-get:*:text/xml:DLNA.ORG_PN=DIDL_S",
                      "http-get:*:audio/flac:*,http-get:*:text/xml:DLNA.ORG_PN=DIDL_S;DLNA.ORG_OP=00"] {
            XCTAssertTrue(UPnPRendererCapabilities(avTransportActions: [], sinkProtocolInfo: value).supportsDIDLPlaylist)
        }
        for value in ["rtsp-rtp-udp:*:text/xml:DLNA.ORG_PN=DIDL_S", "http-get:*:text/xml:*",
                      "http-get:*:text/xml:DLNA.ORG_PN=DIDL_V", "http-get:*:text/xml:DLNA.ORG_PN=DIDL_SOMETHING"] {
            XCTAssertFalse(UPnPRendererCapabilities(avTransportActions: [], sinkProtocolInfo: value).supportsDIDLPlaylist)
        }
    }
}
