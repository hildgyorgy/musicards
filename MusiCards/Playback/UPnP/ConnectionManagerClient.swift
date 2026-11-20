import Foundation

nonisolated struct ConnectionManagerClient: Sendable {
    let service: UPnPServiceDescriptor
    var transport: any UPnPHTTPTransport = URLSessionUPnPHTTPTransport()

    func sinkProtocolInfo() async throws -> String {
        var request = URLRequest(url: service.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.serviceType)#GetProtocolInfo\"", forHTTPHeaderField: "SOAPAction")
        // The service type came from validated device XML. XML-escape it even
        // though conforming UPnP service types contain no markup characters.
        let type = service.serviceType.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetProtocolInfo xmlns:u="\(type)"/></s:Body></s:Envelope>
        """.utf8)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode),
              let sink = try UPnPSOAPResponseParser.parse(data)["Sink"] else {
            throw UPnPDiscoveryError.invalidHTTPResponse
        }
        return sink
    }
}
