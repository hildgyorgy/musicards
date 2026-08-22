//
//  PlaybackModels.swift
//  MusiCards
//

import Foundation

struct PlaybackAudioFormat: Equatable, Sendable {
    let codec: String
    let bitDepth: Int?
    let sampleRate: Double
    let bitrate: Double?
    let channelCount: Int
}

enum PlaybackSeekCapability: Equatable, Hashable, Sendable {
    case supported
    case unsupported

    var isSupported: Bool { self == .supported }

    static func remoteMedia(
        suffix: String?,
        contentType: String?
    ) -> PlaybackSeekCapability {
        let normalizedSuffix = suffix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedContentType = contentType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedSuffix == "flac"
            || normalizedContentType?.hasPrefix("audio/flac") == true
            || normalizedContentType?.hasPrefix("audio/x-flac") == true {
            return .unsupported
        }
        return .supported
    }
}

enum PlaybackSeekError: LocalizedError, Equatable, Sendable {
    case unsupported

    var errorDescription: String? {
        "Seeking is not available for this remote audio format yet."
    }
}

/// MusicBrainz-facing identity and display metadata for one playable track.
/// The audio file remains a separate value so viewer data and local files do
/// not become the same source of truth.
struct PlaybackTrack: Identifiable, Equatable, Sendable {
    let id: String
    let releaseTrackID: String?
    let recordingID: String?
    let releaseID: String?
    let title: String
    let artist: String
    let albumTitle: String
    let duration: TimeInterval?
    let artworkData: Data?
    let mediumFormat: String?
    let discNumber: Int?
    let trackNumber: Int?
    let audioFormat: PlaybackAudioFormat?

    init(
        id: String,
        releaseTrackID: String?,
        recordingID: String?,
        releaseID: String?,
        title: String,
        artist: String,
        albumTitle: String,
        duration: TimeInterval?,
        artworkData: Data?,
        mediumFormat: String? = nil,
        discNumber: Int? = nil,
        trackNumber: Int? = nil,
        audioFormat: PlaybackAudioFormat? = nil
    ) {
        self.id = id
        self.releaseTrackID = releaseTrackID
        self.recordingID = recordingID
        self.releaseID = releaseID
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.duration = duration
        self.artworkData = artworkData
        self.mediumFormat = mediumFormat
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.audioFormat = audioFormat
    }
}

/// Opaque provider-owned identity for an asset that can be resolved for
/// playback without exposing provider-specific location details to callers.
struct PlaybackAssetReference: Equatable, Hashable, Sendable {
    let source: LibrarySource
    let providerItemID: String
    let displayName: String
    let seekCapability: PlaybackSeekCapability

    init(
        source: LibrarySource,
        providerItemID: String,
        displayName: String,
        seekCapability: PlaybackSeekCapability = .supported
    ) {
        self.source = source
        self.providerItemID = providerItemID
        self.displayName = displayName
        self.seekCapability = seekCapability
    }
}

/// Provider-owned factory for an authenticated random-access media source.
/// Authentication remains behind the provider boundary and is never stored in
/// queue items or exposed as an authenticated URL.
@MainActor
protocol RemoteAudioByteSourceProviding: AnyObject, Sendable {
    func makeByteSource() throws -> HTTPRandomAccessByteSource
}

struct RemotePlaybackAsset: Equatable, Sendable {
    let source: LibrarySource
    let providerItemID: String
    let displayName: String
    let mediaSize: Int64
    let suffix: String?
    let contentType: String?
    let seekCapability: PlaybackSeekCapability
    let byteSourceProvider: any RemoteAudioByteSourceProviding

    init(
        source: LibrarySource,
        providerItemID: String,
        displayName: String,
        mediaSize: Int64,
        suffix: String?,
        contentType: String?,
        seekCapability: PlaybackSeekCapability? = nil,
        byteSourceProvider: any RemoteAudioByteSourceProviding
    ) {
        self.source = source
        self.providerItemID = providerItemID
        self.displayName = displayName
        self.mediaSize = mediaSize
        self.suffix = suffix
        self.contentType = contentType
        self.seekCapability = seekCapability ?? .remoteMedia(
            suffix: suffix,
            contentType: contentType
        )
        self.byteSourceProvider = byteSourceProvider
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source
            && lhs.providerItemID == rhs.providerItemID
            && lhs.displayName == rhs.displayName
            && lhs.mediaSize == rhs.mediaSize
            && lhs.suffix == rhs.suffix
            && lhs.contentType == rhs.contentType
            && lhs.seekCapability == rhs.seekCapability
    }
}

/// A concrete engine asset or a provider asset awaiting lazy resolution.
enum PlaybackSource: Equatable, Sendable {
    case localFile(URL)
    case remoteAudio(RemotePlaybackAsset)
    case libraryAsset(PlaybackAssetReference)
}

extension PlaybackSource {
    var seekCapability: PlaybackSeekCapability {
        switch self {
        case .localFile:
            .supported
        case .remoteAudio(let asset):
            asset.seekCapability
        case .libraryAsset(let reference):
            reference.seekCapability
        }
    }
}

/// A queue entry deliberately couples metadata with one playable asset.
struct PlaybackQueueItem: Identifiable, Equatable, Sendable {
    let id: String
    let track: PlaybackTrack
    let source: PlaybackSource

    init(
        id: String? = nil,
        track: PlaybackTrack,
        source: PlaybackSource
    ) {
        self.id = id ?? track.id
        self.track = track
        self.source = source
    }

    func replacingSource(_ source: PlaybackSource) -> PlaybackQueueItem {
        PlaybackQueueItem(id: id, track: track, source: source)
    }
}

/// Source-independent matched library data needed to construct one playback
/// queue entry. The provider retains ownership of the playable asset itself.
struct LibraryPlayableTrack: Equatable, Sendable {
    let id: String
    let releaseTrackID: String?
    let recordingID: String?
    let releaseID: String?
    let fallbackArtist: String
    let duration: TimeInterval?
    let audioFormat: PlaybackAudioFormat?
    let assetReference: PlaybackAssetReference
}

@MainActor
protocol PlaybackAssetResolving: AnyObject {
    func resolvePlaybackAsset(
        _ reference: PlaybackAssetReference
    ) async throws -> PlaybackSource
}

enum PlaybackAssetResolutionError: LocalizedError, Equatable, Sendable {
    case providerUnavailable(LibrarySource)
    case assetUnavailable

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let source):
            "The \(source.rawValue) playback provider is unavailable."
        case .assetUnavailable:
            "The selected audio asset is unavailable."
        }
    }
}

struct PlaybackFailure: Error, Equatable, LocalizedError {
    let message: String

    init(message: String) {
        self.message = message
    }

    init(_ error: Error) {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            message = description
        } else {
            message = error.localizedDescription
        }
    }

    var errorDescription: String? { message }
}

enum PlaybackStatus: Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case stopped
    case failed(PlaybackFailure)

    var isPlaying: Bool {
        self == .playing
    }
}
