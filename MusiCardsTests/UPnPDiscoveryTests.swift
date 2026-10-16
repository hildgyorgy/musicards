import Foundation
import XCTest
@testable import MusiCards

final class UPnPDiscoveryTests: XCTestCase {
    @MainActor
    func testRendererSelectionIsExclusiveAndOnlyCommitsOnConfirmation() {
        let suiteName = "UPnPDiscoveryTests.rendererSelection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let browser = UPnPRendererBrowser(userDefaults: defaults)
        let first = makeRenderer(id: "uuid:first", host: "192.168.1.50")
        let second = makeRenderer(id: "uuid:second", host: "192.168.1.60")

        browser.beginRendererSelection()
        browser.toggleDraftSelection(of: first)
        XCTAssertTrue(browser.isDraftSelected(first))
        XCTAssertFalse(browser.isDraftSelected(second))
        XCTAssertNil(browser.selectedRenderer)

        browser.toggleDraftSelection(of: second)
        XCTAssertFalse(browser.isDraftSelected(first))
        XCTAssertTrue(browser.isDraftSelected(second))

        browser.commitRendererSelection()
        XCTAssertEqual(browser.selectedRenderer?.id, second.id)
        XCTAssertEqual(browser.selectedRendererDisplayName, second.friendlyName)
        XCTAssertEqual(
            defaults.string(forKey: "UPnPSelectedRendererID"),
            second.id
        )

        browser.beginRendererSelection()
        browser.clearDraftRendererSelection()
        browser.cancelRendererSelection()
        XCTAssertTrue(browser.isDraftSelected(second))

        browser.clearDraftRendererSelection()
        browser.commitRendererSelection()
        XCTAssertNil(browser.selectedRenderer)
        XCTAssertNil(browser.selectedRendererDisplayName)
        XCTAssertNil(defaults.string(forKey: "UPnPSelectedRendererID"))

        browser.beginRendererSelection()
        browser.toggleDraftSelection(of: second)
        browser.commitRendererSelection()

        let restoredBrowser = UPnPRendererBrowser(userDefaults: defaults)
        XCTAssertEqual(
            restoredBrowser.selectedRendererDisplayName,
            second.friendlyName
        )

        restoredBrowser.beginRendererSelection()
        restoredBrowser.toggleDraftSelection(of: second)
        restoredBrowser.commitRendererSelection()
        XCTAssertNil(restoredBrowser.selectedRendererDisplayName)
        XCTAssertNil(defaults.string(forKey: "UPnPSelectedRendererID"))
    }

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

    func testSSDPAdvertisementParserAcceptsAliveNotification() throws {
        let data = Data(
            """
            NOTIFY * HTTP/1.1\r
            HOST: 239.255.255.250:1900\r
            NT: urn:schemas-upnp-org:device:MediaRenderer:1\r
            NTS: ssdp:alive\r
            LOCATION: http://192.168.1.60:49152/device.xml\r
            USN: uuid:renderer::urn:schemas-upnp-org:device:MediaRenderer:1\r
            \r
            """.utf8
        )

        let response = try SSDPAdvertisementParser.parseAlive(data)

        XCTAssertEqual(
            response.location,
            URL(string: "http://192.168.1.60:49152/device.xml")
        )
        XCTAssertEqual(response.searchTarget, "urn:schemas-upnp-org:device:MediaRenderer:1")
    }

    func testSSDPAdvertisementParserRejectsByebyeNotification() {
        let data = Data(
            """
            NOTIFY * HTTP/1.1\r
            NT: upnp:rootdevice\r
            NTS: ssdp:byebye\r
            LOCATION: http://192.168.1.60/device.xml\r
            \r
            """.utf8
        )

        XCTAssertThrowsError(try SSDPAdvertisementParser.parseAlive(data))
    }

    func testSubnetCandidatesCoverLocalSlash24ButExcludeReservedAndSelf() {
        let hosts = LocalIPv4Subnet.candidateHosts(
            address: "192.168.0.184",
            netmask: "255.255.255.0"
        )

        XCTAssertEqual(hosts.count, 253)
        XCTAssertTrue(hosts.contains("192.168.0.186"))
        XCTAssertFalse(hosts.contains("192.168.0.0"))
        XCTAssertFalse(hosts.contains("192.168.0.184"))
        XCTAssertFalse(hosts.contains("192.168.0.255"))
    }

    func testSubnetCandidatesBoundBroadPrivateNetworkToLocalSlash24() {
        let hosts = LocalIPv4Subnet.candidateHosts(
            address: "10.42.17.8",
            netmask: "255.255.0.0"
        )

        XCTAssertEqual(hosts.count, 253)
        XCTAssertTrue(hosts.contains("10.42.17.200"))
        XCTAssertFalse(hosts.contains("10.42.18.1"))
    }

    func testSubnetCandidatesRejectPublicNetwork() {
        XCTAssertTrue(
            LocalIPv4Subnet.candidateHosts(
                address: "203.0.113.5",
                netmask: "255.255.255.0"
            ).isEmpty
        )
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

    private func makeRenderer(
        id: String,
        host: String
    ) -> UPnPRendererDescriptor {
        let baseURL = URL(string: "http://\(host)")!
        let avTransport = UPnPServiceDescriptor(
            serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
            serviceID: nil,
            controlURL: baseURL.appending(path: "control"),
            eventSubscriptionURL: nil,
            serviceDescriptionURL: nil
        )
        return UPnPRendererDescriptor(
            friendlyName: id,
            uniqueDeviceName: id,
            manufacturer: nil,
            modelName: nil,
            descriptionURL: baseURL.appending(path: "device.xml"),
            avTransport: avTransport,
            renderingControl: nil,
            connectionManager: nil,
            capabilities: .unknown
        )
    }
}
