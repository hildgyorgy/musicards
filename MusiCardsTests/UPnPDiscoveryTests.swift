import Foundation
import XCTest
@testable import MusiCards

final class UPnPDiscoveryTests: XCTestCase {
    func testSSDPResponseParserUsesCaseInsensitiveHeaders() throws {
        let data = Data(
            """
            HTTP/1.1 200 OK\r
            CACHE-CONTROL: max-age=1800\r
            LoCaTiOn: http://192.168.1.50:49152/device.xml\r
            ST: urn:schemas-upnp-org:device:MediaRenderer:2\r
            USN: uuid:renderer::urn:schemas-upnp-org:device:MediaRenderer:2\r
            SERVER: Test/1.0 UPnP/1.1 Renderer/2.0\r
            \r
            """.utf8
        )

        let response = try SSDPResponseParser.parse(data)

        XCTAssertEqual(
            response.location,
            URL(string: "http://192.168.1.50:49152/device.xml")
        )
        XCTAssertEqual(response.searchTarget, "urn:schemas-upnp-org:device:MediaRenderer:2")
        XCTAssertEqual(response.server, "Test/1.0 UPnP/1.1 Renderer/2.0")
    }

    func testDeviceDescriptionChoosesHighestAVTransportVersionAndResolvesURLs() throws {
        let data = Data(
            """
            <?xml version="1.0"?>
            <root xmlns="urn:schemas-upnp-org:device-1-0">
              <URLBase>http://192.168.1.50:49152/base/</URLBase>
              <device>
                <deviceType>urn:schemas-upnp-org:device:MediaRenderer:2</deviceType>
                <friendlyName>Living Room Renderer</friendlyName>
                <manufacturer>Example Audio</manufacturer>
                <modelName>Reference One</modelName>
                <UDN>uuid:renderer-1</UDN>
                <serviceList>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                    <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
                    <SCPDURL>avtransport1.xml</SCPDURL>
                    <controlURL>/control/avtransport1</controlURL>
                    <eventSubURL>/events/avtransport1</eventSubURL>
                  </service>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType>
                    <serviceId>urn:upnp-org:serviceId:AVTransport2</serviceId>
                    <SCPDURL>avtransport2.xml</SCPDURL>
                    <controlURL>/control/avtransport2</controlURL>
                    <eventSubURL>/events/avtransport2</eventSubURL>
                  </service>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
                    <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
                    <SCPDURL>rendering.xml</SCPDURL>
                    <controlURL>/control/rendering</controlURL>
                    <eventSubURL>/events/rendering</eventSubURL>
                  </service>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                    <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
                    <SCPDURL>connection.xml</SCPDURL>
                    <controlURL>/control/connection</controlURL>
                    <eventSubURL>/events/connection</eventSubURL>
                  </service>
                </serviceList>
              </device>
            </root>
            """.utf8
        )

        let renderer = try UPnPDeviceDescriptionParser.parse(
            data,
            descriptionURL: URL(string: "http://192.168.1.50:49152/device.xml")!
        )

        XCTAssertEqual(renderer.friendlyName, "Living Room Renderer")
        XCTAssertEqual(renderer.uniqueDeviceName, "uuid:renderer-1")
        XCTAssertEqual(renderer.avTransport.version, 2)
        XCTAssertEqual(
            renderer.avTransport.controlURL,
            URL(string: "http://192.168.1.50:49152/control/avtransport2")
        )
        XCTAssertEqual(
            renderer.avTransport.serviceDescriptionURL,
            URL(string: "http://192.168.1.50:49152/base/avtransport2.xml")
        )
        XCTAssertNotNil(renderer.renderingControl)
        XCTAssertNotNil(renderer.connectionManager)
    }

    func testServiceDescriptionFindsOptionalTransportCapabilities() throws {
        let data = Data(
            """
            <?xml version="1.0"?>
            <scpd xmlns="urn:schemas-upnp-org:service-1-0">
              <actionList>
                <action><name>SetAVTransportURI</name></action>
                <action><name>SetNextAVTransportURI</name></action>
                <action><name>Play</name></action>
                <action><name>Pause</name></action>
                <action><name>Seek</name></action>
              </actionList>
            </scpd>
            """.utf8
        )

        let actions = try UPnPServiceDescriptionParser.actionNames(from: data)
        let capabilities = UPnPRendererCapabilities(avTransportActions: actions)

        XCTAssertTrue(capabilities.supportsPlay)
        XCTAssertTrue(capabilities.supportsPause)
        XCTAssertTrue(capabilities.supportsSeek)
        XCTAssertTrue(capabilities.supportsSetNext)
        XCTAssertFalse(capabilities.supportsStop)
    }

    func testDeviceWithoutAVTransportIsRejected() {
        let data = Data(
            """
            <root xmlns="urn:schemas-upnp-org:device-1-0">
              <device>
                <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
                <friendlyName>Incomplete Renderer</friendlyName>
              </device>
            </root>
            """.utf8
        )

        XCTAssertThrowsError(
            try UPnPDeviceDescriptionParser.parse(
                data,
                descriptionURL: URL(string: "http://192.168.1.60/device.xml")!
            )
        ) { error in
            XCTAssertEqual(error as? UPnPDiscoveryError, .missingAVTransport)
        }
    }
}
