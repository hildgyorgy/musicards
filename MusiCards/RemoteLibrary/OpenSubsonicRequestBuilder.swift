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
        salt: String
    ) throws -> URLRequest {
        try authenticatedRequest(
            endpoint: "ping",
            profile: profile,
            password: password,
            salt: salt
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

    private func authenticatedRequest(
        endpoint endpointName: String,
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        additionalParameters: [String: String] = [:],
        accept: String = "application/json"
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: profile.baseURL,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        scheme == "https" else {
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
