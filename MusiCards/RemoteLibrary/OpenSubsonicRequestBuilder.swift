import Foundation

struct OpenSubsonicRequestBuilder: Sendable {
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
        guard var components = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https" else {
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
        components.path = path.hasSuffix("/rest") ? path + "/ping" : path + "/rest/ping"

        guard let endpoint = components.url else {
            throw NavidromeConnectionError.invalidBaseURL
        }

        let parameters = [
            "c": clientName,
            "f": "json",
            "s": salt,
            "t": OpenSubsonicAuthentication.token(password: password, salt: salt),
            "u": profile.username,
            "v": apiVersion
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
