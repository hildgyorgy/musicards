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
    var path: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: DestinationKind,
        user: String? = nil,
        host: String? = nil,
        path: String
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.user = user
        self.host = host
        self.path = path
    }

    var remoteDestination: String {
        switch kind {
        case .remote:
            guard let user, let host else {
                return path
            }

            return "\(user)@\(host):\(path)"

        case .local:
            return path
        }
    }
}

extension DestinationProfile {

    nonisolated static let umbrelRPi5 = DestinationProfile(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Umbrel – RPi 5",
        kind: .remote,
        user: "umbrel",
        host: "umbrel.local",
        path: "/home/umbrel/umbrel/home/Music/"
    )

    nonisolated static let casaOSRPi4 = DestinationProfile(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "CasaOS – RPi 4",
        kind: .remote,
        user: "rpi4",
        host: "192.168.1.33",
        path: "/media/devmon/MUSIC/Music/"
    )

    nonisolated static let defaults: [DestinationProfile] = [
        .umbrelRPi5,
        .casaOSRPi4
    ]
}
