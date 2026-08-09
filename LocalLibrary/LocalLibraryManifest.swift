//
//  LocalLibraryManifest.swift
//  MusiCards
//

import Foundation

nonisolated struct LocalLibraryManifestAlbum: Codable, Sendable {
    let indexVersion: Int?
    let albumName: String?
    let artistName: String?
    let albumMBID: String
    let releaseYear: String?
    let country: String?
    let label: String?
    let mediaFormat: String?
    let folderPath: String
    let tracks: [LocalLibraryManifestTrack]

    enum CodingKeys: String, CodingKey {
        case indexVersion = "index_version"
        case albumName = "album_name"
        case artistName = "artist_name"
        case albumMBID = "album_mbid"
        case releaseYear = "release_year"
        case country
        case label
        case mediaFormat = "media_format"
        case folderPath = "folder_path"
        case tracks
    }
}

nonisolated struct LocalLibraryManifestTrack: Codable, Sendable {
    let filename: String
    let title: String?
    let trackMBID: String?
    let releaseTrackMBID: String?
    let codec: String?
    let bitDepth: Int?
    let sampleRate: Double?
    let bitrate: Double?
    let channels: Int?
    let fileSize: Int64?
    let modifiedNS: Int64?
    let modifiedAt: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case title
        case trackMBID = "track_mbid"
        case releaseTrackMBID = "release_track_mbid"
        case codec
        case bitDepth = "bit_depth"
        case sampleRate = "sample_rate"
        case bitrate
        case channels
        case fileSize = "file_size"
        case modifiedNS = "modified_ns"
        case modifiedAt = "modified_at"
    }
}

enum LocalLibraryManifestLoader {
    nonisolated static let fileName = "library.json"

    nonisolated static func load(
        from rootURL: URL
    ) async throws -> [ScannedAudioFile] {
        let manifestURL = rootURL.appendingPathComponent(fileName)
        let data = try await Task.detached(priority: .utility) {
            try coordinatedData(from: manifestURL)
        }.value
        let albums = try JSONDecoder().decode(
            [LocalLibraryManifestAlbum].self,
            from: data
        )

        var files: [ScannedAudioFile] = []
        for album in albums {
            for track in album.tracks {
                let relativePath = try validatedRelativePath(
                    folderPath: album.folderPath,
                    filename: track.filename
                )
                files.append(
                    ScannedAudioFile(
                        relativePath: relativePath,
                        fileSize: track.fileSize ?? 0,
                        modificationDate: modificationDate(track.modifiedAt),
                        title: track.title ?? URL(fileURLWithPath: track.filename)
                            .deletingPathExtension().lastPathComponent,
                        artist: album.artistName ?? "",
                        albumTitle: album.albumName ?? "",
                        releaseMBID: album.albumMBID,
                        recordingMBID: track.trackMBID,
                        releaseTrackMBID: track.releaseTrackMBID,
                        releaseYear: album.releaseYear,
                        country: album.country,
                        label: album.label,
                        mediaFormat: album.mediaFormat,
                        codec: track.codec ?? URL(fileURLWithPath: track.filename)
                            .pathExtension.uppercased(),
                        bitDepth: track.bitDepth,
                        sampleRate: track.sampleRate ?? 0,
                        bitrate: track.bitrate,
                        channelCount: track.channels ?? 0,
                        duration: nil
                    )
                )
            }
        }
        return files
    }

    private nonisolated static func coordinatedData(
        from url: URL
    ) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }

        if let coordinationError { throw coordinationError }
        guard let result else {
            throw NativePlaybackEngineError(
                "Could not read \(fileName) from the selected folder."
            )
        }
        return try result.get()
    }

    private nonisolated static func validatedRelativePath(
        folderPath: String,
        filename: String
    ) throws -> String {
        let normalizedFolder = folderPath == "." ? "" : folderPath
        let relativePath = [normalizedFolder, filename]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NativePlaybackEngineError(
                "library.json contains an unsafe file path."
            )
        }
        return relativePath
    }

    private nonisolated static func modificationDate(
        _ value: String?
    ) -> Date {
        guard let value else { return .distantPast }
        return ISO8601DateFormatter().date(from: value) ?? .distantPast
    }
}
