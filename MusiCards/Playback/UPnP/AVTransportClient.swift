import Foundation

@MainActor
protocol UPnPHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

@MainActor
struct URLSessionUPnPHTTPTransport: UPnPHTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum AVTransportClientError: Error, Equatable {
    case invalidRenderer
    case invalidResponse
    case httpStatus(Int)
    case soapFault(String)
    case invalidSeekPosition
}

/// Sends standard AVTransport SOAP actions to a discovered renderer.
@MainActor
final class AVTransportClient {
    private let renderer: UPnPRendererDescriptor
    private let transport: any UPnPHTTPTransport

    init(
        renderer: UPnPRendererDescriptor,
        transport: any UPnPHTTPTransport = URLSessionUPnPHTTPTransport()
    ) {
        self.renderer = renderer
        self.transport = transport
    }

    func setCurrent(uri: URL, metadata: String) async throws {
        _ = try await call(
            "SetAVTransportURI",
            arguments: [
                ("CurrentURI", uri.absoluteString),
                ("CurrentURIMetaData", metadata)
            ]
        )
    }

    func setNext(uri: URL, metadata: String) async throws {
        _ = try await call(
            "SetNextAVTransportURI",
            arguments: [
                ("NextURI", uri.absoluteString),
                ("NextURIMetaData", metadata)
            ]
        )
    }

    func play() async throws {
        _ = try await call("Play", arguments: [("Speed", "1")])
    }

    func pause() async throws {
        _ = try await call("Pause")
    }

    func stop() async throws {
        _ = try await call("Stop")
    }

    func seek(to seconds: TimeInterval) async throws {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else {
            throw AVTransportClientError.invalidSeekPosition
        }
        let wholeSeconds = Int(seconds)
        let clock = String(
            format: "%d:%02d:%02d",
            wholeSeconds / 3_600,
            (wholeSeconds % 3_600) / 60,
            wholeSeconds % 60
        )
        _ = try await call(
            "Seek",
            arguments: [("Unit", "REL_TIME"), ("Target", clock)]
        )
    }

    func getTransportInfo() async throws -> Data {
        try await call("GetTransportInfo")
    }

    func getPositionInfo() async throws -> Data {
        try await call("GetPositionInfo")
    }

    func getMediaInfo() async throws -> Data {
        try await call("GetMediaInfo")
    }

    private func call(
        _ action: String,
        arguments: [(String, String)] = []
    ) async throws -> Data {
        let serviceType = renderer.avTransportServiceType
        let servicePrefix = "urn:schemas-upnp-org:service:AVTransport:"
        let version = serviceType.dropFirst(servicePrefix.count)
        guard serviceType.hasPrefix(servicePrefix),
              let versionNumber = Int(version), versionNumber > 0,
              let scheme = renderer.avTransportControlURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              renderer.avTransportControlURL.host != nil,
              renderer.avTransportControlURL.user == nil,
              renderer.avTransportControlURL.password == nil else {
            throw AVTransportClientError.invalidRenderer
        }

        let parameters = arguments.map { name, value in
            "<\(name)>\(Self.escape(value))</\(name)>"
        }.joined()
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(serviceType)"><InstanceID>0</InstanceID>\(parameters)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: renderer.avTransportControlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AVTransportClientError.invalidResponse
        }
        let inspector = SOAPResponseInspector()
        let parser = XMLParser(data: data)
        parser.delegate = inspector
        let isSOAPEnvelope = parser.parse() && inspector.hasEnvelope && inspector.hasBody
        if isSOAPEnvelope, inspector.hasFault {
            throw AVTransportClientError.soapFault(
                inspector.faultMessage ?? "Unknown UPnP fault"
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AVTransportClientError.httpStatus(response.statusCode)
        }
        guard isSOAPEnvelope else {
            throw AVTransportClientError.invalidResponse
        }
        return data
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

nonisolated private final class SOAPResponseInspector: NSObject, XMLParserDelegate {
    private(set) var hasEnvelope = false
    private(set) var hasBody = false
    private(set) var hasFault = false
    private(set) var faultMessage: String?
    private var readingFaultMessage = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
        case "Envelope": hasEnvelope = true
        case "Body": hasBody = true
        case "Fault": hasFault = true
        case "faultstring": readingFaultMessage = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingFaultMessage {
            faultMessage = (faultMessage ?? "") + string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "faultstring" {
            readingFaultMessage = false
        }
    }
}
