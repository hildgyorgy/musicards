import Foundation

nonisolated struct UPnPServiceDescriptor: Hashable, Sendable {
    let serviceType: String
    let serviceID: String?
    let controlURL: URL
    let eventSubscriptionURL: URL?
    let serviceDescriptionURL: URL?

    var version: Int? {
        Int(serviceType.split(separator: ":").last ?? "")
    }
}

nonisolated struct UPnPRendererCapabilities: Hashable, Sendable {
    let avTransportActions: Set<String>

    static let unknown = UPnPRendererCapabilities(avTransportActions: [])

    var supportsPlay: Bool { supports("Play") }
    var supportsPause: Bool { supports("Pause") }
    var supportsStop: Bool { supports("Stop") }
    var supportsSeek: Bool { supports("Seek") }
    var supportsSetNext: Bool { supports("SetNextAVTransportURI") }

    private func supports(_ action: String) -> Bool {
        avTransportActions.contains {
            $0.caseInsensitiveCompare(action) == .orderedSame
        }
    }
}

nonisolated struct UPnPRendererDescriptor: Hashable, Sendable, Identifiable {
    let friendlyName: String
    let uniqueDeviceName: String?
    let manufacturer: String?
    let modelName: String?
    let descriptionURL: URL
    let avTransport: UPnPServiceDescriptor
    let renderingControl: UPnPServiceDescriptor?
    let connectionManager: UPnPServiceDescriptor?
    let capabilities: UPnPRendererCapabilities

    var id: String {
        guard let uniqueDeviceName,
              !uniqueDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return descriptionURL.absoluteString
        }
        return uniqueDeviceName
    }
}

nonisolated struct SSDPDiscoveryResponse: Hashable, Sendable {
    let location: URL
    let searchTarget: String?
    let uniqueServiceName: String?
    let server: String?
}

nonisolated enum UPnPDiscoveryError: LocalizedError, Equatable {
    case socketCreationFailed(Int32)
    case socketConfigurationFailed(Int32)
    case sendFailed(Int32)
    case invalidHTTPResponse
    case invalidDeviceDescription
    case notMediaRenderer
    case missingAVTransport
    case invalidServiceDescription
    case invalidHTTPStatus(Int)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            "The local network discovery socket could not be created."
        case .socketConfigurationFailed:
            "The local network discovery socket could not be configured."
        case .sendFailed:
            "The renderer discovery request could not be sent."
        case .invalidHTTPResponse:
            "The renderer returned an invalid SSDP response."
        case .invalidDeviceDescription:
            "The device description could not be read."
        case .notMediaRenderer:
            "The discovered device is not a UPnP MediaRenderer."
        case .missingAVTransport:
            "The renderer does not advertise an AVTransport service."
        case .invalidServiceDescription:
            "The renderer service description could not be read."
        case let .invalidHTTPStatus(status):
            "The renderer returned HTTP status \(status)."
        }
    }
}
