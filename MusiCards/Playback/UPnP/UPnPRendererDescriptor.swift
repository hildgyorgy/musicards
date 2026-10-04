import Foundation

/// One discovered MediaRenderer and its AVTransport control endpoint.
struct UPnPRendererDescriptor: Hashable, Identifiable, Sendable {
    /// The device UDN is stable across changes to its network address.
    let id: String
    let friendlyName: String
    let descriptionURL: URL
    let avTransportServiceType: String
    let avTransportControlURL: URL
}
