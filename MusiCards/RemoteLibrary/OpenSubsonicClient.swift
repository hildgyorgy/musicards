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
        let envelope: OpenSubsonicPingEnvelope = try await response(
            for: request
        )
        return try NavidromeServerVerifier.identity(from: envelope.response)
    }

    func albumListPage(
        profile: NavidromeServerProfile,
        password: String,
        offset: Int,
        size: Int
    ) async throws -> [OpenSubsonicAlbum] {
        let salt = try OpenSubsonicAuthentication.makeSalt()
        let request = try requestBuilder.albumListRequest(
            profile: profile,
            password: password,
            salt: salt,
            offset: offset,
            size: size
        )
        let envelope: OpenSubsonicAlbumListEnvelope = try await response(
            for: request
        )
        try validate(
            status: envelope.response.status,
            error: envelope.response.error
        )
        return envelope.response.albumList?.albums ?? []
    }

    func album(
        profile: NavidromeServerProfile,
        password: String,
        id: String
    ) async throws -> OpenSubsonicAlbum {
        let salt = try OpenSubsonicAuthentication.makeSalt()
        let request = try requestBuilder.albumRequest(
            profile: profile,
            password: password,
            salt: salt,
            albumID: id
        )
        let envelope: OpenSubsonicAlbumEnvelope = try await response(
            for: request
        )
        try validate(
            status: envelope.response.status,
            error: envelope.response.error
        )
        guard let album = envelope.response.album else {
            throw NavidromeConnectionError.invalidResponse
        }
        return album
    }

    private func response<Response: Decodable>(
        for request: URLRequest
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NavidromeConnectionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NavidromeConnectionError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw NavidromeConnectionError.invalidResponse
        }
    }

    private func validate(
        status: OpenSubsonicStatus,
        error: OpenSubsonicServerError?
    ) throws {
        if status == .failed {
            throw NavidromeConnectionError.serverRejected(
                code: error?.code ?? -1,
                message: error?.message
            )
        }
    }
}
