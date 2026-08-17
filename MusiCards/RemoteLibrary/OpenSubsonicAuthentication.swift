import CryptoKit
import Foundation
import Security

enum OpenSubsonicAuthentication {
    static func token(password: String, salt: String) -> String {
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func makeSalt(byteCount: Int = 16) throws -> String {
        precondition(byteCount >= 6)

        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw OpenSubsonicAuthenticationError.randomGenerationFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum OpenSubsonicAuthenticationError: Error, Equatable, Sendable {
    case randomGenerationFailed(OSStatus)
}
