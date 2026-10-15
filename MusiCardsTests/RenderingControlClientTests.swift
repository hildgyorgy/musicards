import Foundation
import XCTest
@testable import MusiCards

final class RenderingControlClientTests: XCTestCase {
    func testReadsMasterVolumeAndMuteState() async throws {
        let transport = RenderingControlTransportStub()
        let client = RenderingControlClient(
            service: service,
            transport: transport
        )

        let state = try await client.volumeState()

        XCTAssertEqual(state.level, 0.37)
        XCTAssertTrue(state.isMuted)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(try body(requests[0]).contains(
            "<InstanceID>0</InstanceID><Channel>Master</Channel>"
        ))
        XCTAssertTrue(requests[0].value(forHTTPHeaderField: "SOAPAction")?
            .contains("#GetVolume") == true)
        XCTAssertTrue(requests[1].value(forHTTPHeaderField: "SOAPAction")?
            .contains("#GetMute") == true)
    }

    func testWritesClampedVolumeAndMuteUsingMasterChannel() async throws {
        let transport = RenderingControlTransportStub()
        let client = RenderingControlClient(
            service: service,
            transport: transport
        )

        try await client.setVolume(1.4)
        try await client.setMuted(false)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(try body(requests[0]).contains(
            "<Channel>Master</Channel><DesiredVolume>100</DesiredVolume>"
        ))
        XCTAssertTrue(try body(requests[1]).contains(
            "<Channel>Master</Channel><DesiredMute>0</DesiredMute>"
        ))
    }

    private var service: UPnPServiceDescriptor {
        UPnPServiceDescriptor(
            serviceType: "urn:schemas-upnp-org:service:RenderingControl:1",
            serviceID: "urn:upnp-org:serviceId:RenderingControl",
            controlURL: URL(string: "http://192.168.1.50/rendering")!,
            eventSubscriptionURL: nil,
            serviceDescriptionURL: nil
        )
    }

    private func body(_ request: URLRequest) throws -> String {
        try XCTUnwrap(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        )
    }
}

private actor RenderingControlTransportStub: UPnPHTTPTransport {
    private var receivedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        receivedRequests.append(request)
        let action = request.value(forHTTPHeaderField: "SOAPAction") ?? ""
        let responseBody: String
        if action.contains("GetVolume") {
            responseBody = """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
              <s:Body><u:GetVolumeResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
                <CurrentVolume>37</CurrentVolume>
              </u:GetVolumeResponse></s:Body>
            </s:Envelope>
            """
        } else if action.contains("GetMute") {
            responseBody = """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
              <s:Body><u:GetMuteResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
                <CurrentMute>1</CurrentMute>
              </u:GetMuteResponse></s:Body>
            </s:Envelope>
            """
        } else {
            responseBody = """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
              <s:Body><u:Response xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"/></s:Body>
            </s:Envelope>
            """
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (Data(responseBody.utf8), response)
    }

    func requests() -> [URLRequest] {
        receivedRequests
    }
}
