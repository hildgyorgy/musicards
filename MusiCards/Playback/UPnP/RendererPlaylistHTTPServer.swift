import Foundation
import Network
import Darwin

nonisolated protocol RendererPlaylistServing: AnyObject, Sendable {
    func start(document: Data, rendererURL: URL) async throws -> URL
    /// Closes the listener and all connections, erases the XML, and reports a
    /// completed GET. The renderer must confirm its track count separately.
    func finish() async -> Bool
}

/// A short-lived, IPv4 LAN listener serving ONE in-memory XML document, never
/// audio or disk files. It is shut down before Play, and expires independently.
actor RendererPlaylistHTTPServer: RendererPlaylistServing {
    private let queue = DispatchQueue(label: "MusiCards.playlist-handoff")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var expiry: Task<Void, Never>?
    private var pendingStart: CheckedContinuation<URL, Error>?
    private var document = Data()
    private var route: PlaylistLANRoute?
    private var path = ""
    private var served = false
    private var stopped = false
    private var requestCount = 0

    func start(document: Data, rendererURL: URL) async throws -> URL {
        guard listener == nil, !stopped, document.count <= DIDLPlaylistDocument.maximumByteCount else {
            throw RendererPlaylistError.unavailable
        }
        let route = try await Task.detached { try PlaylistLANRoute(to: rendererURL) }.value
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        self.route = route
        self.document = document
        self.path = "/musicards-playlist/\(UUID().uuidString.lowercased())/album.xml"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init(route.localIP), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            _ = await self?.finish()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingStart = continuation
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { _ = await self.finish() }
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard let port = listener?.port, let route,
                  let url = URL(string: "http://\(route.localIP):\(port.rawValue)\(path)") else {
                failStart()
                return
            }
            pendingStart?.resume(returning: url)
            pendingStart = nil
        case .failed:
            failStart()
        default: break
        }
    }

    private func failStart() {
        pendingStart?.resume(throwing: RendererPlaylistError.unavailable)
        pendingStart = nil
        _ = close()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 4, requestCount < 16,
              case let .hostPort(host, _) = connection.endpoint,
              case .ipv4(let address) = host,
              address.debugDescription == route?.rendererIP else {
            connection.cancel()
            return
        }
        requestCount += 1
        let id = UUID()
        connections[id] = connection
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            await self?.closeConnection(id)
        }
        connection.start(queue: queue)
        receive(id, prefix: Data())
    }

    private func receive(_ id: UUID, prefix: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            Task { await self?.received(id, prefix: prefix, data: data, complete: complete, failed: error != nil) }
        }
    }

    private func received(_ id: UUID, prefix: Data, data: Data?, complete: Bool, failed: Bool) {
        guard !stopped, let connection = connections[id] else { return }
        var request = prefix
        request.append(data ?? Data())
        guard request.count <= 8_192 else { respond(connection, id: id, status: "431 Request Header Fields Too Large"); return }
        guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
            if complete || failed { closeConnection(id) } else { receive(id, prefix: request) }
            return
        }
        guard let header = String(data: request[..<end.upperBound], encoding: .utf8),
              let line = header.components(separatedBy: "\r\n").first else { closeConnection(id); return }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])), parts[1] == path else {
            respond(connection, id: id, status: "404 Not Found"); return
        }
        guard parts[0] == "HEAD" || parts[0] == "GET" else {
            respond(connection, id: id, status: "405 Method Not Allowed"); return
        }
        respond(connection, id: id, status: "200 OK", includeBody: parts[0] == "GET", valid: true)
    }

    private func respond(_ connection: NWConnection, id: UUID, status: String, includeBody: Bool = false, valid: Bool = false) {
        var headers = "HTTP/1.1 \(status)\r\nContent-Length: \(valid ? document.count : 0)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if valid {
            // Literal text/xml is required by Rygel's playlist detector.
            headers += "Content-Type: text/xml\r\ncontentFeatures.dlna.org: DLNA.ORG_PN=DIDL_S\r\ntransferMode.dlna.org: Interactive\r\n"
        }
        var response = Data((headers + "\r\n").utf8)
        if includeBody { response.append(document) }
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { await self?.sent(id, downloaded: includeBody && error == nil) }
        })
    }

    private func sent(_ id: UUID, downloaded: Bool) {
        guard !stopped else { return }
        served = served || downloaded
        closeConnection(id)
    }

    private func closeConnection(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
    }

    func finish() -> Bool { close() }

    private func close() -> Bool {
        stopped = true
        pendingStart?.resume(throwing: RendererPlaylistError.unavailable)
        pendingStart = nil
        expiry?.cancel()
        expiry = nil
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { closeConnection(id) }
        document = Data()
        route = nil
        return served
    }
}

nonisolated private struct PlaylistLANRoute: Sendable {
    let localIP: String
    let rendererIP: String

    init(to rendererURL: URL) throws {
        try UPnPEndpointPolicy.validate(rendererURL)
        guard let host = rendererURL.host else { throw RendererPlaylistError.unavailable }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "1900", &hints, &addresses) == 0, let addresses else {
            throw RendererPlaylistError.unavailable
        }
        defer { freeaddrinfo(addresses) }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw RendererPlaylistError.unavailable }
        defer { Darwin.close(fd) }
        guard connect(fd, addresses.pointee.ai_addr, addresses.pointee.ai_addrlen) == 0 else {
            throw RendererPlaylistError.unavailable
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw RendererPlaylistError.unavailable }
        var localBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var peerBuffer = localBuffer
        var peer = addresses.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        guard inet_ntop(AF_INET, &local.sin_addr, &localBuffer, socklen_t(localBuffer.count)) != nil,
              inet_ntop(AF_INET, &peer.sin_addr, &peerBuffer, socklen_t(peerBuffer.count)) != nil else {
            throw RendererPlaylistError.unavailable
        }
        self.localIP = String(cString: localBuffer)
        self.rendererIP = String(cString: peerBuffer)
        // Recheck resolved DNS, not only the originally advertised hostname.
        guard NavidromeRendererServerURL.isLocalHost(rendererIP) else { throw RendererPlaylistError.unavailable }
    }
}
