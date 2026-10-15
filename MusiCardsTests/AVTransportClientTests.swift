import Foundation
import XCTest
@testable import MusiCards

final class AVTransportClientTests: XCTestCase {
    func testSnapshotBuildsSOAPRequestsAndParsesRendererState() async throws {
        let transport = AVTransportTransportStub()
        let client = AVTransportClient(
            service: service,
            transport: transport
        )

        let snapshot = try await client.snapshot()

        XCTAssertEqual(snapshot.transport.state, "PLAYING")
        XCTAssertEqual(snapshot.transport.status, "OK")
        XCTAssertEqual(snapshot.position.trackNumber, 2)
        XCTAssertEqual(snapshot.position.duration, 247)
        XCTAssertEqual(snapshot.position.relativeTime, 83)
        XCTAssertEqual(
            snapshot.position.trackURI,
            URL(string: "http://music.local/rest/stream?id=song-2")
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url, service.controlURL)
            XCTAssertTrue(request.value(forHTTPHeaderField: "SOAPAction")?.contains(
                service.serviceType
            ) == true)
            let body = try XCTUnwrap(
                request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            )
            XCTAssertTrue(body.contains("<InstanceID>0</InstanceID>"))
        }
    }

    func testSOAPFaultIsPresentedAsRendererError() async {
        let transport = AVTransportTransportStub(returnsFault: true)
        let client = AVTransportClient(service: service, transport: transport)

        do {
            _ = try await client.transportStatus()
            XCTFail("Expected SOAP fault")
        } catch {
            XCTAssertEqual(
                error as? AVTransportClientError,
                .soapFault(code: "701", description: "Transition not available")
            )
        }
    }

    private var service: UPnPServiceDescriptor {
        UPnPServiceDescriptor(
            serviceType: "urn:schemas-upnp-org:service:AVTransport:2",
            serviceID: "urn:upnp-org:serviceId:AVTransport",
            controlURL: URL(string: "http://192.168.1.50/control")!,
            eventSubscriptionURL: nil,
            serviceDescriptionURL: nil
        )
    }
}

private actor AVTransportTransportStub: UPnPHTTPTransport {
    private var receivedRequests: [URLRequest] = []
    private let returnsFault: Bool

    init(returnsFault: Bool = false) {
        self.returnsFault = returnsFault
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        receivedRequests.append(request)
        let action = request.value(forHTTPHeaderField: "SOAPAction") ?? ""
        let data: Data
        let statusCode: Int

        if returnsFault {
            statusCode = 500
            data = Data(
                """
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
                  <s:Body><s:Fault><detail><UPnPError>
                    <errorCode>701</errorCode>
                    <errorDescription>Transition not available</errorDescription>
                  </UPnPError></detail></s:Fault></s:Body>
                </s:Envelope>
                """.utf8
            )
        } else if action.contains("GetTransportInfo") {
            statusCode = 200
            data = Data(
                """
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
                  <s:Body><u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:2">
                    <CurrentTransportState>PLAYING</CurrentTransportState>
                    <CurrentTransportStatus>OK</CurrentTransportStatus>
                    <CurrentSpeed>1</CurrentSpeed>
                  </u:GetTransportInfoResponse></s:Body>
                </s:Envelope>
                """.utf8
            )
        } else {
            statusCode = 200
            data = Data(
                """
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
                  <s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:2">
                    <Track>2</Track><TrackDuration>0:04:07</TrackDuration>
                    <RelTime>0:01:23</RelTime>
                    <TrackURI>http://music.local/rest/stream?id=song-2</TrackURI>
                  </u:GetPositionInfoResponse></s:Body>
                </s:Envelope>
                """.utf8
            )
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (data, response)
    }

    func requests() -> [URLRequest] {
        receivedRequests
    }
}
