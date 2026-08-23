import Foundation

nonisolated struct NavidromeServerProfile: Codable, Equatable, Identifiable, Sendable {
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

    static func validated(
        id: UUID = UUID(),
        name: String,
        serverURL: String,
        username: String
    ) throws -> NavidromeServerProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedUsername.isEmpty else {
            throw NavidromeProfileValidationError.usernameRequired
        }
        guard !trimmedURL.isEmpty else {
            throw NavidromeProfileValidationError.serverURLRequired
        }

        if !trimmedURL.contains("://") {
            trimmedURL = "https://\(trimmedURL)"
        }

        guard let components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased() else {
            throw NavidromeProfileValidationError.invalidServerURL
        }
        guard scheme == "https" else {
            if scheme == "http" {
                throw NavidromeProfileValidationError.secureConnectionRequired
            }
            throw NavidromeProfileValidationError.invalidServerURL
        }
        guard let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let baseURL = components.url else {
            throw NavidromeProfileValidationError.invalidServerURL
        }

        return NavidromeServerProfile(
            id: id,
            name: trimmedName.isEmpty ? host : trimmedName,
            baseURL: baseURL,
            username: trimmedUsername
        )
    }
}

nonisolated struct NavidromeServerIdentity: Codable, Equatable, Sendable {
    let serverVersion: String?
    let protocolVersion: String
}

nonisolated struct NavidromeCatalogCredentials: Sendable {
    let profile: NavidromeServerProfile
    let password: String
}

nonisolated enum NavidromeProfileValidationError: LocalizedError, Equatable, Sendable {
    case serverURLRequired
    case usernameRequired
    case secureConnectionRequired
    case invalidServerURL

    var errorDescription: String? {
        switch self {
        case .serverURLRequired:
            "Enter the Navidrome server URL."
        case .usernameRequired:
            "Enter your Navidrome username."
        case .secureConnectionRequired:
            "A remote Navidrome server must use HTTPS."
        case .invalidServerURL:
            "The Navidrome server URL is not valid."
        }
    }
}

nonisolated enum NavidromeConnectionError: LocalizedError, Equatable, Sendable {
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
            "A remote Navidrome server must use HTTPS."
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

nonisolated enum NavidromeServerVerifier {
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
