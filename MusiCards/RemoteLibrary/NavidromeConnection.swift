import Foundation
import Darwin

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

nonisolated enum NavidromeRendererServerURL {
    static func validated(_ value: String) throws -> URL {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NavidromeRendererServerURLError.addressRequired
        }
        if !trimmed.contains("://") {
            trimmed = "http://\(trimmed)"
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            throw NavidromeRendererServerURLError.invalidAddress
        }
        if scheme == "http", !isLocalHost(host) {
            throw NavidromeRendererServerURLError.insecurePublicAddress
        }
        return url
    }

    static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, normalized, &address) == 1 else { return false }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            // Loopback, unique-local and link-local IPv6 only. Public and
            // IPv4-mapped addresses must not bypass the cleartext policy.
            return bytes == Array(repeating: 0, count: 15) + [1]
                || bytes[0] & 0xfe == 0xfc
                || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ label in
            guard let value = UInt8(label) else { return false }
            return String(value) == label
        }) {
            let octets = labels.compactMap { UInt8($0) }
            return octets[0] == 10 || octets[0] == 127
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 169 && octets[1] == 254)
        }
        // Resolvers may interpret hex, octal or shortened IPv4 spellings as
        // IP literals rather than DNS names. Only canonical literals above
        // may pass, never a numeric alias disguised as a single-label host.
        var legacyAddress = in_addr()
        if inet_aton(normalized, &legacyAddress) == 1 { return false }
        // Numeric-looking invalid IPv4 literals are not local hostnames.
        return normalized.hasSuffix(".local")
            || (!normalized.isEmpty && !normalized.contains(".")
                && normalized.contains(where: { $0.isLetter })
                && normalized.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
    }
}

nonisolated enum NavidromeRendererServerURLError:
    LocalizedError, Equatable, Sendable {
    case addressRequired
    case invalidAddress
    case insecurePublicAddress

    var errorDescription: String? {
        switch self {
        case .addressRequired:
            "Enter the Navidrome address reachable from the renderer."
        case .invalidAddress:
            "The renderer's Navidrome address is not valid."
        case .insecurePublicAddress:
            "An HTTP renderer address must be a private or local-network address."
        }
    }
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
