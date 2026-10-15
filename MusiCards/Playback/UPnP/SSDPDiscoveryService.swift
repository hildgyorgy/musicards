import Darwin
import Foundation

nonisolated enum SSDPDiscoveryMode: Sendable {
    case multicast
    case unicast(hosts: [String])
    case passive
    case subnetSweep
}

nonisolated struct SSDPDiscoveryService: Sendable {
    private let multicastAddress = "239.255.255.250"
    private let multicastPort: UInt16 = 1900

    func discover(
        timeout: TimeInterval = 2.5,
        mode: SSDPDiscoveryMode
    ) async throws -> [SSDPDiscoveryResponse] {
        try await Task.detached(priority: .userInitiated) {
            try discoverBlocking(
                timeout: timeout,
                mode: mode
            )
        }.value
    }

    private func discoverBlocking(
        timeout: TimeInterval,
        mode: SSDPDiscoveryMode
    ) throws -> [SSDPDiscoveryResponse] {
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

        let targets = [
            "urn:schemas-upnp-org:device:MediaRenderer:2",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "upnp:rootdevice"
        ]
        let listenerDescriptor: Int32?
        switch mode {
        case .multicast:
            try sendRequests(
                socketDescriptor: socketDescriptor,
                hosts: [multicastAddress],
                targets: targets,
                rounds: 2
            )
            listenerDescriptor = nil
        case let .unicast(hosts):
            guard !hosts.isEmpty else { return [] }
            try sendRequests(
                socketDescriptor: socketDescriptor,
                hosts: hosts,
                targets: targets,
                rounds: 2
            )
            listenerDescriptor = nil
        case .passive:
            listenerDescriptor = try makeAdvertisementListener()
        case .subnetSweep:
            let hosts = LocalIPv4Subnet.activeCandidateHosts()
            guard !hosts.isEmpty else { return [] }
            try sendRequests(
                socketDescriptor: socketDescriptor,
                hosts: hosts,
                targets: targets,
                rounds: 1
            )
            listenerDescriptor = nil
        }

        let deadline = Date().addingTimeInterval(max(0.25, timeout))
        var responsesByLocation: [URL: SSDPDiscoveryResponse] = [:]
        var buffer = [UInt8](repeating: 0, count: 65_535)
        defer {
            if let listenerDescriptor { close(listenerDescriptor) }
        }

        while true {
            let remainingMilliseconds = Int32(
                max(0, deadline.timeIntervalSinceNow * 1_000).rounded(.up)
            )
            guard remainingMilliseconds > 0 else { break }

            var descriptors = [
                pollfd(fd: socketDescriptor, events: Int16(POLLIN), revents: 0)
            ]
            if let listenerDescriptor {
                descriptors.append(
                    pollfd(fd: listenerDescriptor, events: Int16(POLLIN), revents: 0)
                )
            }
            let pollResult = descriptors.withUnsafeMutableBufferPointer {
                poll($0.baseAddress, nfds_t($0.count), remainingMilliseconds)
            }
            if pollResult == 0 { break }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw UPnPDiscoveryError.socketConfigurationFailed(errno)
            }

            for descriptor in descriptors where descriptor.revents & Int16(POLLIN) != 0 {
                let byteCount = recv(descriptor.fd, &buffer, buffer.count, 0)
                guard byteCount > 0 else { continue }
                let data = Data(buffer.prefix(byteCount))
                let response: SSDPDiscoveryResponse?
                if descriptor.fd == socketDescriptor {
                    response = try? SSDPResponseParser.parse(data)
                } else {
                    response = try? SSDPAdvertisementParser.parseAlive(data)
                }
                if let response {
                    responsesByLocation[response.location] = response
                }
            }
        }

        return responsesByLocation.values.sorted {
            $0.location.absoluteString < $1.location.absoluteString
        }
    }

    private func sendRequests(
        socketDescriptor: Int32,
        hosts: [String],
        targets: [String],
        rounds: Int
    ) throws {
        let destinations = hosts.compactMap(makeDestination)
        guard !destinations.isEmpty else {
            throw UPnPDiscoveryError.socketConfigurationFailed(EINVAL)
        }

        var sentRequest = false
        var lastSendError: Int32 = 0
        for round in 0..<rounds {
            for target in targets {
                let payload = mSearchPayload(target: target)
                for var destination in destinations {
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
                    if sent == payload.count {
                        sentRequest = true
                    } else {
                        lastSendError = errno
                    }
                }
            }
            if round + 1 < rounds {
                usleep(100_000)
            }
        }
        guard sentRequest else {
            throw UPnPDiscoveryError.sendFailed(lastSendError)
        }
    }

    private func makeAdvertisementListener() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw UPnPDiscoveryError.socketCreationFailed(errno)
        }

        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEPORT,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let error = errno
            close(descriptor)
            throw UPnPDiscoveryError.socketConfigurationFailed(error)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = multicastPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else {
            let error = errno
            close(descriptor)
            throw UPnPDiscoveryError.socketConfigurationFailed(error)
        }

        var membership = ip_mreq()
        guard inet_pton(AF_INET, multicastAddress, &membership.imr_multiaddr) == 1 else {
            close(descriptor)
            throw UPnPDiscoveryError.socketConfigurationFailed(EINVAL)
        }
        membership.imr_interface = in_addr(s_addr: INADDR_ANY)
        guard setsockopt(
            descriptor,
            IPPROTO_IP,
            IP_ADD_MEMBERSHIP,
            &membership,
            socklen_t(MemoryLayout<ip_mreq>.size)
        ) == 0 else {
            let error = errno
            close(descriptor)
            throw UPnPDiscoveryError.socketConfigurationFailed(error)
        }
        return descriptor
    }

    private func makeDestination(address: String) -> sockaddr_in? {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = multicastPort.bigEndian
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else {
            return nil
        }
        return destination
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

    func discover(
        timeout: TimeInterval = 2.5,
        mode: SSDPDiscoveryMode
    ) async throws -> [UPnPRendererDescriptor] {
        let responses = try await ssdp.discover(
            timeout: timeout,
            mode: mode
        )
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

nonisolated enum LocalIPv4Subnet {
    private static let maximumCandidateCount = 254

    static func activeCandidateHosts() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var result: Set<String> = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }
            let required = UInt32(IFF_UP | IFF_RUNNING)
            guard interface.ifa_flags & required == required,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let rawAddress = interface.ifa_addr,
                  let rawNetmask = interface.ifa_netmask,
                  rawAddress.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let address = UnsafeRawPointer(rawAddress)
                .assumingMemoryBound(to: sockaddr_in.self).pointee
            let netmask = UnsafeRawPointer(rawNetmask)
                .assumingMemoryBound(to: sockaddr_in.self).pointee
            result.formUnion(
                candidateHosts(
                    address: UInt32(bigEndian: address.sin_addr.s_addr),
                    netmask: UInt32(bigEndian: netmask.sin_addr.s_addr)
                )
            )
        }
        return result.sorted()
    }

    static func candidateHosts(address: String, netmask: String) -> [String] {
        guard let addressValue = ipv4Value(address),
              let netmaskValue = ipv4Value(netmask) else { return [] }
        return candidateHosts(address: addressValue, netmask: netmaskValue)
    }

    private static func candidateHosts(
        address: UInt32,
        netmask: UInt32
    ) -> [String] {
        guard isPrivate(address) else { return [] }

        var effectiveMask = netmask
        var network = address & effectiveMask
        var broadcast = network | ~effectiveMask
        let availableCount = broadcast > network ? broadcast - network - 1 : 0
        if availableCount > maximumCandidateCount {
            effectiveMask = 0xFF_FF_FF_00
            network = address & effectiveMask
            broadcast = network | ~effectiveMask
        }
        guard broadcast > network + 1 else { return [] }

        return ((network + 1)..<broadcast).compactMap { candidate in
            guard candidate != address else { return nil }
            return ipv4String(candidate)
        }
    }

    private static func isPrivate(_ address: UInt32) -> Bool {
        (address & 0xFF_00_00_00) == 0x0A_00_00_00
            || (address & 0xFF_F0_00_00) == 0xAC_10_00_00
            || (address & 0xFF_FF_00_00) == 0xC0_A8_00_00
    }

    private static func ipv4Value(_ string: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func ipv4String(_ value: UInt32) -> String? {
        var address = in_addr(s_addr: value.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }
}
