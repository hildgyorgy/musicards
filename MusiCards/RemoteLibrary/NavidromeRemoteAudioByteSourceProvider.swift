import Foundation

/// Keeps OpenSubsonic authentication inside the Navidrome layer. The playback
/// engine receives only a byte-source factory, never credentials or an
/// authenticated request URL.
@MainActor
final class NavidromeRemoteAudioByteSourceProvider:
    RemoteAudioByteSourceProviding
{
    private let connection: any NavidromeCatalogConnectionProviding
    private let songID: String
    private let mediaSize: Int64

    init(
        connection: any NavidromeCatalogConnectionProviding,
        songID: String,
        mediaSize: Int64
    ) {
        self.connection = connection
        self.songID = songID
        self.mediaSize = mediaSize
    }

    func makeByteSource() throws -> HTTPRandomAccessByteSource {
        let credentials = try connection.catalogCredentials()
        let salt = try OpenSubsonicAuthentication.makeSalt()
        let request = try OpenSubsonicRequestBuilder().streamRequest(
            profile: credentials.profile,
            password: credentials.password,
            salt: salt,
            songID: songID
        )
        return try HTTPRandomAccessByteSource(
            baseRequest: request,
            length: mediaSize
        )
    }
}
