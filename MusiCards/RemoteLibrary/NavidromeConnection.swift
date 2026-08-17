import Foundation

struct NavidromeServerProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var baseURL: URL
    var username: String

    init(id: UUID = UUID(), name: String, baseURL: URL, username: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.username = username
    }
}

struct NavidromeServerIdentity: Equatable, Sendable {
    let serverVersion: String?
    let protocolVersion: String
}

enum NavidromeConnectionError: LocalizedError, Equatable, Sendable {
    case secureConnectionRequired
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int)
    case serverRejected(code: Int, message: String?)
    case openSubsonicRequired
    case notNavidrome(serverType: String?)

    var errorDescription: String? {
        switch self {
        case .secureConnectionRequired:
            "A remote music server must use HTTPS."
        case .invalidBaseURL:
            "The server URL is not valid."
        case .invalidResponse:
            "The server returned an unreadable response."
        case .httpStatus(let code):
            "The server returned HTTP status \(code)."
        case .serverRejected(_, let message):
            message ?? "The server rejected the connection."
        case .openSubsonicRequired:
            "This server does not advertise modern OpenSubsonic support."
        case .notNavidrome:
            "This connection currently supports Navidrome servers only."
        }
    }
}

enum NavidromeServerVerifier {
    static func identity(from response: OpenSubsonicPingResponse) throws -> NavidromeServerIdentity {
        if response.status == .failed {
            throw NavidromeConnectionError.serverRejected(
                code: response.error?.code ?? -1,
                message: response.error?.message
            )
        }
        guard response.openSubsonic == true else {
            throw NavidromeConnectionError.openSubsonicRequired
        }
        guard response.type?.caseInsensitiveCompare("navidrome") == .orderedSame else {
            throw NavidromeConnectionError.notNavidrome(serverType: response.type)
        }
        return NavidromeServerIdentity(
            serverVersion: response.serverVersion,
            protocolVersion: response.version
        )
    }
}
