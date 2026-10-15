import Foundation

nonisolated enum SSDPResponseParser {
    static func parse(_ data: Data) throws -> SSDPDiscoveryResponse {
        let message = try SSDPMessageParser.parse(data)
        guard message.startLine.uppercased().hasPrefix("HTTP/1.1 200") else {
            throw UPnPDiscoveryError.invalidHTTPResponse
        }
        return try SSDPMessageParser.response(
            headers: message.headers,
            targetHeader: "st"
        )
    }
}

nonisolated enum SSDPAdvertisementParser {
    static func parseAlive(_ data: Data) throws -> SSDPDiscoveryResponse {
        let message = try SSDPMessageParser.parse(data)
        guard message.startLine.uppercased().hasPrefix("NOTIFY * HTTP/1.1"),
              message.headers["nts"]?.lowercased() == "ssdp:alive" else {
            throw UPnPDiscoveryError.invalidHTTPResponse
        }
        return try SSDPMessageParser.response(
            headers: message.headers,
            targetHeader: "nt"
        )
    }
}

private nonisolated enum SSDPMessageParser {
    struct Message {
        let startLine: String
        let headers: [String: String]
    }

    static func parse(_ data: Data) throws -> Message {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UPnPDiscoveryError.invalidHTTPResponse
        }
        let lines = text.components(separatedBy: .newlines)
        guard let startLine = lines.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !startLine.isEmpty else {
            throw UPnPDiscoveryError.invalidHTTPResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            headers[name] = value
        }
        return Message(startLine: startLine, headers: headers)
    }

    static func response(
        headers: [String: String],
        targetHeader: String
    ) throws -> SSDPDiscoveryResponse {
        guard let locationText = headers["location"],
              let location = URL(string: locationText) else {
            throw UPnPDiscoveryError.invalidHTTPResponse
        }

        return SSDPDiscoveryResponse(
            location: location,
            searchTarget: headers[targetHeader],
            uniqueServiceName: headers["usn"],
            server: headers["server"]
        )
    }
}

nonisolated enum UPnPDeviceDescriptionParser {
    static func parse(
        _ data: Data,
        descriptionURL: URL,
        capabilities: UPnPRendererCapabilities = .unknown
    ) throws -> UPnPRendererDescriptor {
        let delegate = DeviceDescriptionXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.parseError == nil else {
            throw UPnPDiscoveryError.invalidDeviceDescription
        }

        let values = delegate.deviceValues
        let deviceType = values["deviceType"] ?? ""
        guard deviceType.localizedCaseInsensitiveContains("MediaRenderer") else {
            throw UPnPDiscoveryError.notMediaRenderer
        }

        let baseURL = delegate.urlBase.flatMap(URL.init(string:)) ?? descriptionURL
        let services = delegate.services.compactMap {
            serviceDescriptor(from: $0, baseURL: baseURL)
        }
        guard let avTransport = preferredService(
            containing: "schemas-upnp-org:service:AVTransport:",
            in: services
        ) else {
            throw UPnPDiscoveryError.missingAVTransport
        }

        return UPnPRendererDescriptor(
            friendlyName: nonBlank(values["friendlyName"]) ?? "UPnP Renderer",
            uniqueDeviceName: nonBlank(values["UDN"]),
            manufacturer: nonBlank(values["manufacturer"]),
            modelName: nonBlank(values["modelName"]),
            descriptionURL: descriptionURL,
            avTransport: avTransport,
            renderingControl: preferredService(
                containing: "schemas-upnp-org:service:RenderingControl:",
                in: services
            ),
            connectionManager: preferredService(
                containing: "schemas-upnp-org:service:ConnectionManager:",
                in: services
            ),
            capabilities: capabilities
        )
    }

    private static func serviceDescriptor(
        from values: [String: String],
        baseURL: URL
    ) -> UPnPServiceDescriptor? {
        guard let serviceType = nonBlank(values["serviceType"]),
              let controlURL = resolvedURL(values["controlURL"], baseURL: baseURL) else {
            return nil
        }
        return UPnPServiceDescriptor(
            serviceType: serviceType,
            serviceID: nonBlank(values["serviceId"]),
            controlURL: controlURL,
            eventSubscriptionURL: resolvedURL(values["eventSubURL"], baseURL: baseURL),
            serviceDescriptionURL: resolvedURL(values["SCPDURL"], baseURL: baseURL)
        )
    }

    private static func preferredService(
        containing marker: String,
        in services: [UPnPServiceDescriptor]
    ) -> UPnPServiceDescriptor? {
        services
            .filter { $0.serviceType.localizedCaseInsensitiveContains(marker) }
            .max { ($0.version ?? 0) < ($1.version ?? 0) }
    }

    private static func resolvedURL(_ value: String?, baseURL: URL) -> URL? {
        guard let value = nonBlank(value) else { return nil }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : value
    }
}

nonisolated enum UPnPServiceDescriptionParser {
    static func actionNames(from data: Data) throws -> Set<String> {
        let delegate = ServiceDescriptionXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.parseError == nil else {
            throw UPnPDiscoveryError.invalidServiceDescription
        }
        return delegate.actionNames
    }
}

private nonisolated final class DeviceDescriptionXMLDelegate:
    NSObject, XMLParserDelegate {
    var deviceValues: [String: String] = [:]
    var services: [[String: String]] = []
    var urlBase: String?
    var parseError: Error?

    private var elementStack: [String] = []
    private var text = ""
    private var currentService: [String: String]?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        elementStack.append(name)
        text = ""
        if name == "service" {
            currentService = [:]
        }
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
        let name = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentService != nil, name != "service", !value.isEmpty {
            currentService?[name] = value
        } else if name == "service", let service = currentService {
            services.append(service)
            currentService = nil
        } else if name == "URLBase", !value.isEmpty {
            urlBase = value
        } else if ["deviceType", "friendlyName", "UDN", "manufacturer", "modelName"]
            .contains(name), deviceValues[name] == nil, !value.isEmpty {
            deviceValues[name] = value
        }

        _ = elementStack.popLast()
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private nonisolated final class ServiceDescriptionXMLDelegate:
    NSObject, XMLParserDelegate {
    var actionNames: Set<String> = []
    var parseError: Error?

    private var insideAction = false
    private var currentElement = ""
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = localName(elementName)
        text = ""
        if currentElement == "action" {
            insideAction = true
        }
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
        let name = localName(elementName)
        if insideAction, name == "name" {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { actionNames.insert(value) }
        } else if name == "action" {
            insideAction = false
        }
        currentElement = ""
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private nonisolated func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}
