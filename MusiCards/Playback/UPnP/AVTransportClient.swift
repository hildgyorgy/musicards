import Foundation
import OSLog

nonisolated protocol UPnPHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated final class URLSessionUPnPHTTPTransport:
    UPnPHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw UPnPDiscoveryError.invalidHTTPResponse
        }
        return (data, response)
    }
}

nonisolated struct AVTransportStatus: Equatable, Sendable {
    let state: String
    let status: String?
    let speed: String?
}

nonisolated struct AVTransportPosition: Equatable, Sendable {
    let trackNumber: Int?
    let duration: TimeInterval?
    let relativeTime: TimeInterval?
    let trackURI: URL?
}

nonisolated struct AVTransportSnapshot: Equatable, Sendable {
    let transport: AVTransportStatus
    let position: AVTransportPosition
}

nonisolated protocol AVTransportControlling: Sendable {
    func snapshot() async throws -> AVTransportSnapshot
    func setTransportURI(_ uri: URL, metadata: String) async throws
    func setNextTransportURI(_ uri: URL?, metadata: String) async throws
    func play() async throws
    func pause() async throws
    func stop() async throws
    func seek(to position: TimeInterval) async throws
}

nonisolated enum AVTransportClientError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case soapFault(code: String?, description: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The renderer returned an invalid AVTransport response."
        case let .httpStatus(status):
            "The renderer returned HTTP status \(status)."
        case let .soapFault(code, description):
            description?.nilIfEmpty
                ?? code.map { "The renderer returned UPnP error \($0)." }
                ?? "The renderer rejected the AVTransport request."
        }
    }
}

nonisolated struct AVTransportClient: Sendable {
    private static let logger = Logger(
        subsystem: "com.hildgyorgy.MusiCards",
        category: "AVTransport"
    )
    private let service: UPnPServiceDescriptor
    private let transport: any UPnPHTTPTransport

    init(
        service: UPnPServiceDescriptor,
        transport: any UPnPHTTPTransport = URLSessionUPnPHTTPTransport()
    ) {
        self.service = service
        self.transport = transport
    }

    func snapshot() async throws -> AVTransportSnapshot {
        let transportStatus = try await transportStatus()
        let position = try await positionInfo()
        return AVTransportSnapshot(
            transport: transportStatus,
            position: position
        )
    }

    func transportStatus() async throws -> AVTransportStatus {
        let values = try await call(action: "GetTransportInfo")
        guard let state = values["CurrentTransportState"]?.nilIfEmpty else {
            throw AVTransportClientError.invalidResponse
        }
        return AVTransportStatus(
            state: state,
            status: values["CurrentTransportStatus"]?.nilIfEmpty,
            speed: values["CurrentSpeed"]?.nilIfEmpty
        )
    }

    func positionInfo() async throws -> AVTransportPosition {
        let values = try await call(action: "GetPositionInfo")
        return AVTransportPosition(
            trackNumber: values["Track"].flatMap(Int.init),
            duration: Self.timeInterval(values["TrackDuration"]),
            relativeTime: Self.timeInterval(values["RelTime"]),
            trackURI: values["TrackURI"]?.nilIfEmpty.flatMap(URL.init(string:))
        )
    }

    func setTransportURI(_ uri: URL, metadata: String) async throws {
        _ = try await call(
            action: "SetAVTransportURI",
            arguments: [
                ("CurrentURI", uri.absoluteString),
                ("CurrentURIMetaData", metadata)
            ]
        )
    }

    func setNextTransportURI(_ uri: URL?, metadata: String) async throws {
        _ = try await call(
            action: "SetNextAVTransportURI",
            arguments: [
                ("NextURI", uri?.absoluteString ?? ""),
                ("NextURIMetaData", uri == nil ? "" : metadata)
            ]
        )
    }

    func play() async throws {
        _ = try await call(action: "Play", arguments: [("Speed", "1")])
    }

    func pause() async throws {
        _ = try await call(action: "Pause")
    }

    func stop() async throws {
        _ = try await call(action: "Stop")
    }

    func seek(to position: TimeInterval) async throws {
        _ = try await call(
            action: "Seek",
            arguments: [
                ("Unit", "REL_TIME"),
                ("Target", Self.timeString(position))
            ]
        )
    }

    private func call(
        action: String,
        arguments: [(String, String)] = []
    ) async throws -> [String: String] {
        var request = URLRequest(url: service.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(
            "text/xml; charset=\"utf-8\"",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "\"\(service.serviceType)#\(action)\"",
            forHTTPHeaderField: "SOAPAction"
        )
        request.httpBody = Self.envelope(
            serviceType: service.serviceType,
            action: action,
            arguments: [("InstanceID", "0")] + arguments
        )

        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.data(for: request)
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "AVTransport request failed action=\(action, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            throw error
        }
        let (data, response) = result
        if action != "GetTransportInfo" && action != "GetPositionInfo"
            || !(200..<300 ~= response.statusCode) {
            // Never log SOAP bodies or authenticated media URLs.
            Self.logger.notice(
                "AVTransport response action=\(action, privacy: .public) status=\(response.statusCode, privacy: .public)"
            )
        }
        guard 200..<300 ~= response.statusCode else {
            if let fault = try? UPnPSOAPResponseParser.parse(data),
               fault["errorCode"] != nil || fault["errorDescription"] != nil {
                throw AVTransportClientError.soapFault(
                    code: fault["errorCode"],
                    description: fault["errorDescription"]
                )
            }
            throw AVTransportClientError.httpStatus(response.statusCode)
        }
        return try UPnPSOAPResponseParser.parse(data)
    }

    private static func envelope(
        serviceType: String,
        action: String,
        arguments: [(String, String)]
    ) -> Data {
        let argumentXML = arguments.map { name, value in
            "<\(name)>\(xmlEscaped(value))</\(name)>"
        }.joined()
        return Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
              <s:Body>
                <u:\(action) xmlns:u="\(xmlEscaped(serviceType))">\(argumentXML)</u:\(action)>
              </s:Body>
            </s:Envelope>
            """.utf8
        )
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func timeInterval(_ value: String?) -> TimeInterval? {
        guard let value = value?.nilIfEmpty else { return nil }
        let parts = value.split(separator: ":").compactMap(Double.init)
        guard parts.count == 3 else { return nil }
        return parts[0] * 3_600 + parts[1] * 60 + parts[2]
    }

    private static func timeString(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval.rounded()), 0)
        return String(
            format: "%d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }
}

extension AVTransportClient: AVTransportControlling {}

nonisolated enum UPnPSOAPResponseParser {
    static func parse(_ data: Data) throws -> [String: String] {
        let delegate = SOAPLeafValueXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.parseError == nil else {
            throw AVTransportClientError.invalidResponse
        }
        return delegate.values
    }
}

private nonisolated final class SOAPLeafValueXMLDelegate:
    NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var parseError: Error?

    private var currentElement = ""
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = soapLocalName(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = soapLocalName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == currentElement, !value.isEmpty {
            values[name] = value
        }
        currentElement = ""
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private nonisolated func soapLocalName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

private nonisolated extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
