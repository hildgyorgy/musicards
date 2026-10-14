import Darwin
import Foundation

nonisolated struct SSDPDiscoveryService: Sendable {
    private let multicastAddress = "239.255.255.250"
    private let multicastPort: UInt16 = 1900

    func discover(timeout: TimeInterval = 2.5) async throws -> [SSDPDiscoveryResponse] {
        try await Task.detached(priority: .userInitiated) {
            try discoverBlocking(timeout: timeout)
        }.value
    }

    private func discoverBlocking(timeout: TimeInterval) throws -> [SSDPDiscoveryResponse] {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else {
            throw UPnPDiscoveryError.socketCreationFailed(errno)
        }
        defer { close(socketDescriptor) }

        var localAddress = sockaddr_in()
        localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_port = 0
        localAddress.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw UPnPDiscoveryError.socketConfigurationFailed(errno)
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = multicastPort.bigEndian
        guard inet_pton(AF_INET, multicastAddress, &destination.sin_addr) == 1 else {
            throw UPnPDiscoveryError.socketConfigurationFailed(errno)
        }

        let targets = [
            "urn:schemas-upnp-org:device:MediaRenderer:2",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "upnp:rootdevice"
        ]
        for round in 0..<2 {
            for target in targets {
                let payload = mSearchPayload(target: target)
                let sent = payload.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &destination) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(
                                socketDescriptor,
                                bytes.baseAddress,
                                bytes.count,
                                0,
                                $0,
                                socklen_t(MemoryLayout<sockaddr_in>.size)
                            )
                        }
                    }
                }
                guard sent == payload.count else {
                    throw UPnPDiscoveryError.sendFailed(errno)
                }
            }
            if round == 0 {
                usleep(100_000)
            }
        }

        let deadline = Date().addingTimeInterval(max(0.25, timeout))
        var responsesByLocation: [URL: SSDPDiscoveryResponse] = [:]
        var buffer = [UInt8](repeating: 0, count: 65_535)

        while true {
            let remainingMilliseconds = Int32(
                max(0, deadline.timeIntervalSinceNow * 1_000).rounded(.up)
            )
            guard remainingMilliseconds > 0 else { break }

            var descriptor = pollfd(
                fd: socketDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = poll(&descriptor, 1, remainingMilliseconds)
            if pollResult == 0 { break }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw UPnPDiscoveryError.socketConfigurationFailed(errno)
            }

            let byteCount = recv(socketDescriptor, &buffer, buffer.count, 0)
            guard byteCount > 0 else { continue }
            let data = Data(buffer.prefix(byteCount))
            guard let response = try? SSDPResponseParser.parse(data) else { continue }
            responsesByLocation[response.location] = response
        }

        return responsesByLocation.values.sorted {
            $0.location.absoluteString < $1.location.absoluteString
        }
    }

    private func mSearchPayload(target: String) -> Data {
        Data(
            [
                "M-SEARCH * HTTP/1.1",
                "HOST: \(multicastAddress):\(multicastPort)",
                "MAN: \"ssdp:discover\"",
                "MX: 1",
                "ST: \(target)",
                "",
                ""
            ].joined(separator: "\r\n").utf8
        )
    }
}

nonisolated struct UPnPRendererInspector: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func inspect(descriptionURL: URL) async throws -> UPnPRendererDescriptor {
        let descriptionData = try await load(descriptionURL)
        let preliminary = try UPnPDeviceDescriptionParser.parse(
            descriptionData,
            descriptionURL: descriptionURL
        )

        var actions: Set<String> = []
        if let serviceDescriptionURL = preliminary.avTransport.serviceDescriptionURL {
            if let serviceData = try? await load(serviceDescriptionURL),
               let parsedActions = try? UPnPServiceDescriptionParser.actionNames(
                   from: serviceData
               ) {
                actions = parsedActions
            }
        }

        return try UPnPDeviceDescriptionParser.parse(
            descriptionData,
            descriptionURL: descriptionURL,
            capabilities: UPnPRendererCapabilities(avTransportActions: actions)
        )
    }

    private func load(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UPnPDiscoveryError.invalidHTTPResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw UPnPDiscoveryError.invalidHTTPStatus(httpResponse.statusCode)
        }
        return data
    }
}

nonisolated struct UPnPRendererDiscoveryService: Sendable {
    private let ssdp: SSDPDiscoveryService
    private let inspector: UPnPRendererInspector

    init(
        ssdp: SSDPDiscoveryService = .init(),
        inspector: UPnPRendererInspector = .init()
    ) {
        self.ssdp = ssdp
        self.inspector = inspector
    }

    func discover(timeout: TimeInterval = 2.5) async throws -> [UPnPRendererDescriptor] {
        let responses = try await ssdp.discover(timeout: timeout)
        var renderersByID: [String: UPnPRendererDescriptor] = [:]

        await withTaskGroup(of: UPnPRendererDescriptor?.self) { group in
            for response in responses {
                group.addTask {
                    try? await inspector.inspect(descriptionURL: response.location)
                }
            }
            for await renderer in group {
                if let renderer {
                    renderersByID[renderer.id] = renderer
                }
            }
        }

        return renderersByID.values.sorted {
            $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending
        }
    }
}
