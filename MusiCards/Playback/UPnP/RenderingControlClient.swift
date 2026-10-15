import Foundation

nonisolated struct PlaybackVolumeState: Equatable, Sendable {
    let level: Double
    let isMuted: Bool

    init(level: Double, isMuted: Bool) {
        self.level = min(max(level, 0), 1)
        self.isMuted = isMuted
    }
}

@MainActor
protocol PlaybackVolumeControlling: AnyObject {
    var canControlVolume: Bool { get }

    func outputVolumeState() async throws -> PlaybackVolumeState?
    func setOutputVolume(_ level: Double) async throws -> PlaybackVolumeState?
    func setOutputMuted(_ isMuted: Bool) async throws -> PlaybackVolumeState?
}

nonisolated protocol RenderingControlControlling: Sendable {
    func volumeState() async throws -> PlaybackVolumeState
    func setVolume(_ level: Double) async throws
    func setMuted(_ isMuted: Bool) async throws
}

nonisolated enum RenderingControlClientError:
    LocalizedError, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case soapFault(code: String?, description: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The renderer returned an invalid volume response."
        case let .httpStatus(status):
            "The renderer returned HTTP status \(status) for volume control."
        case let .soapFault(code, description):
            description.flatMap(Self.nonBlank)
                ?? code.map { "The renderer returned UPnP volume error \($0)." }
                ?? "The renderer rejected the volume request."
        }
    }

    private static func nonBlank(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : value
    }
}

nonisolated struct RenderingControlClient: RenderingControlControlling {
    private let service: UPnPServiceDescriptor
    private let transport: any UPnPHTTPTransport

    init(
        service: UPnPServiceDescriptor,
        transport: any UPnPHTTPTransport = URLSessionUPnPHTTPTransport()
    ) {
        self.service = service
        self.transport = transport
    }

    func volumeState() async throws -> PlaybackVolumeState {
        let volumeValues = try await call(
            action: "GetVolume",
            arguments: [("Channel", "Master")]
        )
        let muteValues = try await call(
            action: "GetMute",
            arguments: [("Channel", "Master")]
        )
        guard let rawVolume = volumeValues["CurrentVolume"].flatMap(Int.init),
              let isMuted = Self.boolValue(muteValues["CurrentMute"]) else {
            throw RenderingControlClientError.invalidResponse
        }
        return PlaybackVolumeState(
            level: Double(min(max(rawVolume, 0), 100)) / 100,
            isMuted: isMuted
        )
    }

    func setVolume(_ level: Double) async throws {
        let rawVolume = Int((min(max(level, 0), 1) * 100).rounded())
        _ = try await call(
            action: "SetVolume",
            arguments: [
                ("Channel", "Master"),
                ("DesiredVolume", String(rawVolume))
            ]
        )
    }

    func setMuted(_ isMuted: Bool) async throws {
        _ = try await call(
            action: "SetMute",
            arguments: [
                ("Channel", "Master"),
                ("DesiredMute", isMuted ? "1" : "0")
            ]
        )
    }

    private func call(
        action: String,
        arguments: [(String, String)]
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

        let (data, response) = try await transport.data(for: request)
        guard 200..<300 ~= response.statusCode else {
            if let fault = try? UPnPSOAPResponseParser.parse(data),
               fault["errorCode"] != nil || fault["errorDescription"] != nil {
                throw RenderingControlClientError.soapFault(
                    code: fault["errorCode"],
                    description: fault["errorDescription"]
                )
            }
            throw RenderingControlClientError.httpStatus(response.statusCode)
        }
        do {
            return try UPnPSOAPResponseParser.parse(data)
        } catch {
            throw RenderingControlClientError.invalidResponse
        }
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

    private static func boolValue(_ value: String?) -> Bool? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": true
        case "0", "false", "no": false
        default: nil
        }
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
