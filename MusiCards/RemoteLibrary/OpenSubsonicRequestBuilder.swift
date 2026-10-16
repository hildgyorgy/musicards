import Foundation

nonisolated struct OpenSubsonicRequestBuilder: Sendable {
    let clientName: String
    let apiVersion: String

    init(clientName: String = "MusiCards", apiVersion: String = "1.16.1") {
        self.clientName = clientName
        self.apiVersion = apiVersion
    }

    func pingRequest(
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        allowsInsecureLocalHTTP: Bool = false
    ) throws -> URLRequest {
        try authenticatedRequest(
            endpoint: "ping",
            profile: profile,
            password: password,
            salt: salt,
            allowsInsecureLocalHTTP: allowsInsecureLocalHTTP
        )
    }

    func albumListRequest(
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        offset: Int,
        size: Int
    ) throws -> URLRequest {
        try authenticatedRequest(
            endpoint: "getAlbumList2",
            profile: profile,
            password: password,
            salt: salt,
            additionalParameters: [
                "offset": String(offset),
                "size": String(size),
                "type": "alphabeticalByName"
            ]
        )
    }

    func albumRequest(
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        albumID: String
    ) throws -> URLRequest {
        try authenticatedRequest(
            endpoint: "getAlbum",
            profile: profile,
            password: password,
            salt: salt,
            additionalParameters: ["id": albumID]
        )
    }

    func songRequest(
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        songID: String
    ) throws -> URLRequest {
        try authenticatedRequest(
            endpoint: "getSong",
            profile: profile,
            password: password,
            salt: salt,
            additionalParameters: ["id": songID]
        )
    }

    func streamRequest(
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        songID: String
    ) throws -> URLRequest {
        try authenticatedRequest(
            endpoint: "stream",
            profile: profile,
            password: password,
            salt: salt,
            additionalParameters: [
                "format": "raw",
                "id": songID
            ],
            accept: "audio/*, application/octet-stream"
        )
    }

    /// A renderer-fetchable stream URL. Unlike the app's own byte-source
    /// request this carries OpenSubsonic authentication in the URL because the
    /// UPnP renderer performs the HTTP request itself.
    func rendererStreamURL(
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        songID: String
    ) throws -> URL {
        guard var components = URLComponents(
            url: profile.baseURL,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        scheme == "https" || scheme == "http" else {
            throw NavidromeConnectionError.secureConnectionRequired
        }
        guard components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw NavidromeConnectionError.invalidBaseURL
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path.hasSuffix("/rest")
            ? path + "/stream.view"
            : path + "/rest/stream.view"
        components.queryItems = [
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "format", value: "raw"),
            URLQueryItem(name: "id", value: songID),
            URLQueryItem(name: "maxBitRate", value: "0"),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(
                name: "t",
                value: OpenSubsonicAuthentication.token(
                    password: password,
                    salt: salt
                )
            ),
            URLQueryItem(name: "u", value: profile.username),
            URLQueryItem(name: "v", value: apiVersion)
        ]

        guard let url = components.url else {
            throw NavidromeConnectionError.invalidBaseURL
        }
        return url
    }

    private func authenticatedRequest(
        endpoint endpointName: String,
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        additionalParameters: [String: String] = [:],
        accept: String = "application/json",
        allowsInsecureLocalHTTP: Bool = false
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: profile.baseURL,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        let host = components.host,
        scheme == "https"
            || (scheme == "http"
                && (allowsInsecureLocalHTTP
                    || NavidromeRendererServerURL.isLocalHost(host))) else {
            throw NavidromeConnectionError.secureConnectionRequired
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw NavidromeConnectionError.invalidBaseURL
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path.hasSuffix("/rest")
            ? path + "/\(endpointName)"
            : path + "/rest/\(endpointName)"

        guard let endpoint = components.url else {
            throw NavidromeConnectionError.invalidBaseURL
        }

        var parameters = [
            "c": clientName,
            "f": "json",
            "s": salt,
            "t": OpenSubsonicAuthentication.token(password: password, salt: salt),
            "u": profile.username,
            "v": apiVersion
        ]
        parameters.merge(additionalParameters) { _, additional in additional }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(parameters)
        return request
    }

    private static func formEncoded(_ parameters: [String: String]) -> Data {
        let body = parameters.keys.sorted().map { key in
            "\(encode(key))=\(encode(parameters[key] ?? ""))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func encode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(decoding: [byte], as: UTF8.self)
            case 0x20:
                return "+"
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }
}
