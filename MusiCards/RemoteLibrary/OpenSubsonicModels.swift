import Foundation

nonisolated struct OpenSubsonicPingEnvelope: Decodable, Sendable {
    let response: OpenSubsonicPingResponse

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

nonisolated struct OpenSubsonicPingResponse: Decodable, Sendable {
    let status: OpenSubsonicStatus
    let version: String
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: OpenSubsonicServerError?
}

nonisolated enum OpenSubsonicStatus: String, Decodable, Sendable {
    case ok
    case failed
}

nonisolated struct OpenSubsonicServerError: Decodable, Sendable {
    let code: Int
    let message: String?
}

nonisolated struct OpenSubsonicAlbumListEnvelope: Decodable, Sendable {
    let response: OpenSubsonicAlbumListResponse

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

nonisolated struct OpenSubsonicAlbumListResponse: Decodable, Sendable {
    let status: OpenSubsonicStatus
    let albumList: OpenSubsonicAlbumList?
    let error: OpenSubsonicServerError?

    enum CodingKeys: String, CodingKey {
        case status
        case albumList = "albumList2"
        case error
    }
}

nonisolated struct OpenSubsonicAlbumList: Decodable, Sendable {
    let albums: [OpenSubsonicAlbum]

    enum CodingKeys: String, CodingKey {
        case albums = "album"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        albums = try container.decodeIfPresent(
            [OpenSubsonicAlbum].self,
            forKey: .albums
        ) ?? []
    }
}

nonisolated struct OpenSubsonicAlbumEnvelope: Decodable, Sendable {
    let response: OpenSubsonicAlbumResponse

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

nonisolated struct OpenSubsonicAlbumResponse: Decodable, Sendable {
    let status: OpenSubsonicStatus
    let album: OpenSubsonicAlbum?
    let error: OpenSubsonicServerError?
}

nonisolated struct OpenSubsonicAlbum: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let artist: String?
    let artists: [OpenSubsonicArtist]
    let musicBrainzID: String?
    let songs: [OpenSubsonicSong]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artist
        case artists
        case musicBrainzID = "musicBrainzId"
        case songs = "song"
    }

    init(
        id: String,
        name: String,
        musicBrainzID: String?,
        artist: String? = nil,
        artists: [OpenSubsonicArtist] = [],
        songs: [OpenSubsonicSong] = []
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artists = artists
        self.musicBrainzID = musicBrainzID
        self.songs = songs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        artists = try container.decodeIfPresent(
            [OpenSubsonicArtist].self,
            forKey: .artists
        ) ?? []
        musicBrainzID = try container.decodeIfPresent(
            String.self,
            forKey: .musicBrainzID
        )
        songs = try container.decodeIfPresent(
            [OpenSubsonicSong].self,
            forKey: .songs
        ) ?? []
    }
}

nonisolated struct OpenSubsonicArtist: Decodable, Equatable, Sendable {
    let id: String
    let name: String
}

nonisolated struct OpenSubsonicSong: Decodable, Equatable, Sendable {
    let id: String
    let musicBrainzID: String?
    let title: String?
    let suffix: String?
    let contentType: String?
    let size: Int64?
    let duration: Int?
    let bitRate: Int?
    let samplingRate: Int?
    let bitDepth: Int?
    let channelCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case musicBrainzID = "musicBrainzId"
        case title
        case suffix
        case contentType
        case size
        case duration
        case bitRate
        case samplingRate
        case bitDepth
        case channelCount
    }

    init(
        id: String,
        musicBrainzID: String?,
        title: String? = nil,
        suffix: String? = nil,
        contentType: String? = nil,
        size: Int64? = nil,
        duration: Int? = nil,
        bitRate: Int? = nil,
        samplingRate: Int? = nil,
        bitDepth: Int? = nil,
        channelCount: Int? = nil
    ) {
        self.id = id
        self.musicBrainzID = musicBrainzID
        self.title = title
        self.suffix = suffix
        self.contentType = contentType
        self.size = size
        self.duration = duration
        self.bitRate = bitRate
        self.samplingRate = samplingRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
    }
}
