import Foundation
import XCTest
@testable import MusiCards

final class UPnPProtocolTests: XCTestCase {
    @MainActor
    func testDIDLLiteEscapesMetadataAndKeepsStreamURL() throws {
        let track = PlaybackTrack(
            id: "track-1",
            releaseTrackID: nil,
            recordingID: nil,
            releaseID: nil,
            title: "A & <B>",
            artist: "One \"Two\"",
            albumTitle: "It's good",
            duration: 125,
            artworkData: nil
        )
        let streamURL = try XCTUnwrap(URL(string: "http://server.local/rest/stream?id=1&format=raw"))

        let metadata = try DIDLLiteMetadataBuilder.makeMetadata(
            for: track,
            itemID: "id&1",
            streamURL: streamURL,
            mimeType: "audio/flac"
        )

        XCTAssertTrue(metadata.contains("id=\"id&amp;1\""))
        XCTAssertTrue(metadata.contains("<dc:title>A &amp; &lt;B&gt;</dc:title>"))
        XCTAssertTrue(metadata.contains("<upnp:artist>One &quot;Two&quot;</upnp:artist>"))
        XCTAssertTrue(metadata.contains("<upnp:album>It&apos;s good</upnp:album>"))
        XCTAssertTrue(metadata.contains("duration=\"0:02:05\""))
        XCTAssertTrue(metadata.contains("http://server.local/rest/stream?id=1&amp;format=raw"))
        XCTAssertTrue(XMLParser(data: Data(metadata.utf8)).parse())
    }

    @MainActor
    func testDIDLLiteRejectsMissingMIMEType() {
        XCTAssertThrowsError(try DIDLLiteMetadataBuilder.makeMetadata(
            for: track,
            itemID: "item",
            streamURL: URL(string: "http://server.local/stream")!,
            mimeType: "  "
        )) { error in
            XCTAssertEqual(error as? DIDLLiteMetadataError, .missingMIMEType)
        }
    }

    @MainActor
    func testSetNextSendsEscapedMetadataInSOAPBody() async throws {
        let transport = UPnPHTTPTransportSpy(responseBody: successResponse)
        let client = AVTransportClient(renderer: renderer, transport: transport)
        let uri = try XCTUnwrap(URL(string: "http://server.local/stream?id=1&format=raw"))

        try await client.setNext(uri: uri, metadata: "<DIDL-Lite>A & B</DIDL-Lite>")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, renderer.avTransportControlURL)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "SOAPAction"),
            "\"urn:schemas-upnp-org:service:AVTransport:1#SetNextAVTransportURI\""
        )
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("<InstanceID>0</InstanceID>"))
        XCTAssertTrue(body.contains("<NextURI>http://server.local/stream?id=1&amp;format=raw</NextURI>"))
        XCTAssertTrue(body.contains("<NextURIMetaData>&lt;DIDL-Lite&gt;A &amp; B&lt;/DIDL-Lite&gt;</NextURIMetaData>"))
        XCTAssertTrue(XMLParser(data: Data(body.utf8)).parse())
    }

    @MainActor
    func testSeekUsesRelativeTimeClock() async throws {
        let transport = UPnPHTTPTransportSpy(responseBody: successResponse)
        let client = AVTransportClient(renderer: renderer, transport: transport)

        try await client.seek(to: 3_661.8)

        let body = try XCTUnwrap(transport.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("<Unit>REL_TIME</Unit><Target>1:01:01</Target>"))
    }

    @MainActor
    func testSOAPFaultIsReported() async throws {
        let fault = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultstring>Transition not available</faultstring></s:Fault></s:Body></s:Envelope>
        """
        let transport = UPnPHTTPTransportSpy(responseBody: fault, statusCode: 500)
        let client = AVTransportClient(renderer: renderer, transport: transport)

        do {
            try await client.play()
            XCTFail("Expected SOAP fault")
        } catch {
            XCTAssertEqual(error as? AVTransportClientError, .soapFault("Transition not available"))
        }
    }

    @MainActor
    private var renderer: UPnPRendererDescriptor {
        UPnPRendererDescriptor(
            id: "uuid:avm-1",
            friendlyName: "AVM",
            descriptionURL: URL(string: "http://avm.local/description.xml")!,
            avTransportServiceType: "urn:schemas-upnp-org:service:AVTransport:1",
            avTransportControlURL: URL(string: "http://avm.local/control")!
        )
    }

    @MainActor
    private var track: PlaybackTrack {
        PlaybackTrack(
            id: "track-1",
            releaseTrackID: nil,
            recordingID: nil,
            releaseID: nil,
            title: "Track",
            artist: "Artist",
            albumTitle: "Album",
            duration: nil,
            artworkData: nil
        )
    }

    private var successResponse: String {
        """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:PlayResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/></s:Body></s:Envelope>
        """
    }
}

@MainActor
private final class UPnPHTTPTransportSpy: UPnPHTTPTransport {
    private let responseBody: String
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(responseBody: String, statusCode: Int = 200) {
        self.responseBody = responseBody
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(responseBody.utf8), response)
    }
}
