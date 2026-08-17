import Foundation

struct OpenSubsonicPingEnvelope: Decodable, Sendable {
    let response: OpenSubsonicPingResponse

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct OpenSubsonicPingResponse: Decodable, Sendable {
    let status: OpenSubsonicStatus
    let version: String
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: OpenSubsonicServerError?
}

enum OpenSubsonicStatus: String, Decodable, Sendable {
    case ok
    case failed
}

struct OpenSubsonicServerError: Decodable, Sendable {
    let code: Int
    let message: String?
}
