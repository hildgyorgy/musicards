import Foundation

nonisolated enum DestinationKind: String, Codable, Sendable {
    case remote
    case local
}

nonisolated struct DestinationProfile:
    Codable,
    Identifiable,
    Equatable,
    Hashable,
    Sendable {

    var id: UUID
    var name: String
    var kind: DestinationKind

    var user: String?
    var host: String?
    var port: Int?
    var path: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: DestinationKind,
        user: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        path: String
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.user = user
        self.host = host
        self.port = port
        self.path = path
    }

    var sshPort: Int {
        port ?? 22
    }

    var remoteDestination: String {
        switch kind {
        case .remote:
            guard let user, let host,
                  SSHInvocation.isValidUsername(user),
                  SSHInvocation.isValidHostname(host) else {
                return ""
            }
            return "\(user)@\(host):\(path)"

        case .local:
            return path
        }
    }

    func validatedRemoteDestination() throws -> String {
        guard kind == .remote, let user, let host else {
            return path
        }
        return try SSHInvocation.remoteDestination(
            username: user,
            hostname: host,
            path: path
        )
    }
}

extension DestinationProfile {
    nonisolated static let unconfigured = DestinationProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Choose Destination",
        kind: .local,
        path: ""
    )
}
