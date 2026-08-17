import Foundation

actor OpenSubsonicClient {
    private let session: URLSession
    private let requestBuilder: OpenSubsonicRequestBuilder

    init(
        session: URLSession = .shared,
        requestBuilder: OpenSubsonicRequestBuilder = .init()
    ) {
        self.session = session
        self.requestBuilder = requestBuilder
    }

    func identifyNavidrome(
        profile: NavidromeServerProfile,
        password: String
    ) async throws -> NavidromeServerIdentity {
        let salt = try OpenSubsonicAuthentication.makeSalt()
        let request = try requestBuilder.pingRequest(
            profile: profile,
            password: password,
            salt: salt
        )
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NavidromeConnectionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NavidromeConnectionError.httpStatus(httpResponse.statusCode)
        }

        let envelope: OpenSubsonicPingEnvelope
        do {
            envelope = try JSONDecoder().decode(OpenSubsonicPingEnvelope.self, from: data)
        } catch {
            throw NavidromeConnectionError.invalidResponse
        }
        return try NavidromeServerVerifier.identity(from: envelope.response)
    }
}
